import Foundation
import Synchronization

// The stall watchdog that bounds model downloading, so a wedged download can't pin `isProcessing`
// for the life of the process.
// Why: docs/concurrency.md#why-anything-here-is-bounded-at-all

/// Counts forward progress reported by a download, so a watchdog can tell "slow" from "wedged".
///
/// Only the count's *changing* is meaningful, which is why wrap-around (`&+`) is fine. `Sendable`
/// and lock-guarded because WhisperKit's `ProgressCallback` is `@Sendable` and is invoked from
/// whatever context the Hub downloader is on, never the main actor.
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

/// Thrown by `withStallWatchdog` when `idle` elapses with no reported progress. Its own type, not a
/// `TranscriptionError`, so each caller maps it to its own case.
struct StallTimeout: Error, Equatable {
    /// The silence that was waited through.
    let idle: Duration
}

extension TranscriptionManager {
    /// Run `operation`, failing with `StallTimeout` if `ticker` reports no progress for `idle`.
    /// A slow-but-progressing operation is never penalized, however long it takes.
    ///
    /// Why: docs/concurrency.md#stall-watchdog
    ///
    /// - Parameters:
    ///   - idle: how long a silence may last before the operation is treated as wedged.
    ///   - poll: how often that silence is checked. Granularity, not precision — the effective
    ///     detection window is `idle` rounded up to the next poll.
    ///   - ticker: the ticker the operation reports progress into. A ticker nobody ticks turns
    ///     `idle` into a plain wall-clock deadline, which is how the load ceiling is expressed.
    ///   - drain: how long to wait, after cancelling a stalled operation, for it to actually unwind
    ///     before the failure is reported.
    ///   - operation: the work to bound. Runs on the main actor, like its caller.
    // DO NOT rewrite this as a `withThrowingTaskGroup` racing the operation against a sleep — the
    // group awaits every child at scope exit, so a wedged operation re-wedges the group.
    // Why: docs/concurrency.md#abandon-not-await
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
        // Cancel BOTH on the way out: the arm awaiting the operation can't run its `defer` until
        // `work.value` returns, so a cancellation-deaf operation would leave the watchdog polling.
        defer {
            work.cancel()
            state.watchdog?.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                once.attach(continuation)

                let watchdog = Task { @MainActor in
                    // MUST be suspending, not continuous — a closed lid must not count as a stall.
                    // Why: docs/concurrency.md#suspending-clock
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

                        // MUST latch the verdict before draining — WhisperKit's Hub answers a
                        // cancelled download with a *success* pointing at an incomplete snapshot.
                        // Why: docs/concurrency.md#abandon-not-await
                        state.isTimingOut = true
                        work.cancel()

                        // Then give it a moment to actually stop, bounded so an operation that
                        // ignores cancellation can't re-wedge us here.
                        // Why: docs/concurrency.md#the-drain
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
            Task { @MainActor in once.finish(.failure(CancellationError())) }
        }
    }
}

/// Shared between the watchdog arm and the arm awaiting the operation: `isTimingOut` latches the
/// verdict so a late completion can't overturn it, and `didFinish` lets the drain end early.
@MainActor
private final class Drain {
    var isTimingOut = false
    var didFinish = false
    /// Held so the caller's scope can stop the watchdog too — see the `defer` above.
    var watchdog: Task<Void, Never>?
}

/// A continuation resumable from several racing arms, keeping the first result and discarding every
/// later one. It also tolerates a result arriving *before* the continuation does, which is what
/// makes the cancellation handler above safe.
@MainActor
private final class OneShot<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var isDone = false

    /// Hand over the continuation. Called exactly once, but a result may already be waiting.
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
