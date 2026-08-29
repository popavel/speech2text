import Foundation
import Synchronization

// The stall watchdog that bounds model downloading. `startTranscription()` flips `status` to
// `.loadingModel` before awaiting the download, so an await that never returns pins `isProcessing`
// true for the rest of the process: the Transcribe button stays disabled, the status line reads
// "Downloading and loading model..." forever, and Sparkle's relaunch-postpone loop
// (`UpdaterDelegate` in Updater.swift) polls a busy flag that will never clear.
//
// That is reachable today. WhisperKit's Hub downloader looks defended — a 10s request timeout and
// 5 retries — but the retry budget RESETS on every 10 MB chunk written, so a connection that
// trickles a chunk now and then retries forever; and the metadata phase that precedes each file
// runs on `URLSession.shared`, whose resource timeout is 7 days. Neither is configurable through
// any WhisperKit-level API.

/// Counts forward progress reported by a download, so a watchdog can tell "slow" from "wedged".
///
/// Only the count's *changing* is meaningful — the value itself is never interpreted, which is why
/// wrap-around (`&+`) is fine and why the ticker doesn't care what a "unit" of progress is.
///
/// `Sendable` and lock-guarded because WhisperKit's `ProgressCallback` is `@Sendable` and is
/// invoked from whatever context the Hub downloader is on, never the main actor.
final class ProgressTicker: Sendable {
    private let counter = Mutex<UInt64>(0)

    /// Record one report of forward progress.
    func tick() {
        counter.withLock { $0 &+= 1 }
    }

    /// The current count. Compare successive reads; don't read meaning into the value.
    var count: UInt64 {
        counter.withLock { $0 }
    }
}

/// Thrown by `withStallWatchdog` when `idle` elapses with no reported progress. Deliberately its
/// own type rather than a `TranscriptionError`: the two phases this guards fail for different
/// reasons and tell the user different things, so each caller maps it to its own case.
struct StallTimeout: Error, Equatable {
    /// The silence that was waited through.
    let idle: Duration
}

extension TranscriptionManager {
    /// Run `operation`, failing with `StallTimeout` if `ticker` reports no progress for `idle`. A
    /// slow-but-progressing operation is never penalized, however long it takes — which is the
    /// whole reason this is a stall watchdog and not a deadline: a 1.5 GB model on a thin link
    /// legitimately takes hours, so any wall-clock timeout generous enough to be safe would be too
    /// generous to be useful.
    ///
    /// A caller with nothing to tick from can still use this as a plain ceiling: a ticker nobody
    /// ticks makes `idle` a wall-clock deadline. `loadModel(named:)` uses it both ways.
    ///
    /// **The loser is abandoned, not awaited.** The obvious spelling — a `withThrowingTaskGroup`
    /// racing the operation against a sleep — cannot work here: the group awaits every child at
    /// scope exit, so a wedged operation would wedge the group and reproduce the exact bug this
    /// guards against. So the operation runs in an unstructured task and whichever arm finishes
    /// first resumes the caller through `OneShot`, which drops the late arrival.
    ///
    /// **Never keep what an abandoned operation returns.** WhisperKit's Hub *swallows*
    /// cancellation: `HubApi.snapshot` returns its destination URL as a success when the task is
    /// cancelled mid-download, pointing at an incomplete snapshot. So the stall path throws and
    /// the caller must not cache anything the abandoned task produces later.
    ///
    /// Cancelling the operation on the way out is best-effort — it only stops work that honors
    /// cancellation — but it is what keeps a wedged download from holding its socket and writing
    /// into the model cache after we've already reported failure. `drain` then holds the failure
    /// back until it has actually stopped, because BOTH recoveries available to the user race that
    /// orphan, not just the obvious one: an immediate retry starts a second downloader on the same
    /// partial file, and "delete the downloaded models" is admitted too (`wipeDirectory` only
    /// guards on `isProcessing`, which is already false once the error lands) — a delete that runs
    /// under a live writer can leave a repopulated snapshot whose `.metadata` disagrees with what
    /// is on disk, so the *next* attempt resumes from a stale offset.
    ///
    /// Neither is fatal — every outcome is one more delete away from clean, and Settings re-walks
    /// and reports residual bytes — and `drain` makes both unlikely rather than likely. What it is
    /// not is a lock: an operation deaf to cancellation is abandoned when the drain elapses,
    /// because a recovery path that waits indefinitely on a wedged task is the bug this file
    /// exists to remove.
    ///
    /// - Parameters:
    ///   - idle: how long a silence may last before the operation is treated as wedged.
    ///   - poll: how often that silence is checked. Granularity, not precision: the effective
    ///     detection window is `idle` rounded up to the next poll.
    ///   - ticker: the ticker the operation reports progress into.
    ///   - drain: how long to wait, after cancelling a stalled operation, for it to actually
    ///     unwind before the failure is reported. See `Drain` below.
    ///   - operation: the work to bound. Runs on the main actor, like its caller; the awaits inside
    ///     it (network, file I/O) leave the actor as usual.
    static func withStallWatchdog<T: Sendable>(
        idle: Duration,
        poll: Duration,
        ticker: ProgressTicker,
        drain: Duration = .seconds(5),
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let once = OneShot<T>()
        let state = Drain()
        let work = Task { @MainActor in try await operation() }
        // Cancel BOTH on the way out. The watchdog is normally stopped by the arm awaiting the
        // operation, but that arm can't run its `defer` until `work.value` returns — so against a
        // cancellation-deaf operation, a cancelled caller would otherwise leave the watchdog
        // polling the main actor until `idle` elapsed, long after the caller was gone.
        defer {
            work.cancel()
            state.watchdog?.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                once.attach(continuation)

                let watchdog = Task { @MainActor in
                    // SUSPENDING, not continuous: `ContinuousClock` keeps counting while the
                    // machine is asleep, so a closed lid longer than `idle` would make the first
                    // poll after wake declare a stall on a download that never had a chance to
                    // resume. What this measures is "has progress happened lately *while we were
                    // running*", which is exactly what a suspending clock counts.
                    var lastSeen = ticker.count
                    var lastChange = SuspendingClock.now
                    while true {
                        // Cancelled means the operation won the race; there is nothing to watch.
                        do { try await Task.sleep(for: poll) } catch { return }

                        let seen = ticker.count
                        if seen != lastSeen {
                            lastSeen = seen
                            lastChange = .now
                            continue
                        }
                        guard SuspendingClock.now - lastChange >= idle else { continue }

                        // Latch the verdict BEFORE draining, so an operation that completes
                        // during the drain can't win the race and hand back its result. For the
                        // download this matters concretely: WhisperKit's Hub answers a cancelled
                        // download with a *success* pointing at an incomplete snapshot.
                        state.isTimingOut = true
                        work.cancel()

                        // Then give it a moment to actually stop. The user's retry — which the
                        // error message invites — would otherwise start a second downloader
                        // writing the same `.incomplete` file as an orphan that hasn't noticed
                        // cancellation yet, and nothing locks that path. Bounded, because an
                        // operation that ignores cancellation must not re-wedge us here: after
                        // `drain` we report the failure regardless.
                        let deadline = SuspendingClock.now + drain
                        while !state.didFinish, SuspendingClock.now < deadline {
                            do { try await Task.sleep(for: poll) } catch { break }
                        }

                        once.finish(.failure(StallTimeout(idle: idle)))
                        return
                    }
                }

                state.watchdog = watchdog

                Task { @MainActor in
                    // Whatever the outcome, stop the watchdog — otherwise a completed download
                    // would leave it polling until the idle window elapsed.
                    defer {
                        state.didFinish = true
                        watchdog.cancel()
                    }
                    do {
                        let value = try await work.value
                        guard !state.isTimingOut else { return }
                        once.finish(.success(value))
                    } catch {
                        guard !state.isTimingOut else { return }
                        once.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            // The caller is parked on a continuation, which cancellation cannot reach on its own.
            // Hop back to the actor and resume it; `defer` above then cancels the operation.
            Task { @MainActor in once.finish(.failure(CancellationError())) }
        }
    }
}

/// Shared between the watchdog arm and the arm awaiting the operation: `isTimingOut` latches the
/// verdict so a late completion can't overturn it, and `didFinish` is how the watchdog knows the
/// orphan has actually stopped and the drain can end early.
@MainActor
private final class Drain {
    var isTimingOut = false
    var didFinish = false
    /// Held so the caller's scope can stop the watchdog too — see the `defer` above.
    var watchdog: Task<Void, Never>?
}

/// A continuation that can be resumed from several racing arms, keeping the first result and
/// discarding every later one. It also tolerates a result arriving *before* the continuation does,
/// which is what makes the cancellation handler above safe: cancellation can land while
/// `withCheckedThrowingContinuation` is still handing over the continuation.
@MainActor
private final class OneShot<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var isDone = false

    /// Hand over the continuation. Called exactly once, before any arm can win — but a result may
    /// already be waiting, in which case it is delivered immediately.
    func attach(_ continuation: CheckedContinuation<T, Error>) {
        guard !isDone else { return }
        if let pending {
            isDone = true
            self.pending = nil
            continuation.resume(with: pending)
        } else {
            self.continuation = continuation
        }
    }

    /// Resume the caller with `result`, unless some other arm got there first.
    func finish(_ result: Result<T, Error>) {
        guard !isDone else { return }
        if let continuation {
            isDone = true
            self.continuation = nil
            continuation.resume(with: result)
        } else if pending == nil {
            pending = result
        }
    }
}
