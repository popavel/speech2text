import Foundation
import Synchronization
import Testing

@testable import Speech2Text

// Tests for the model-download stall watchdog (Speech2Text/ModelDownloadWatchdog.swift).
//
// `stallingOperationIsAbandoned` and `tickingOperationSurvivesPastIdleWindow` are the two halves of
// the "slow is fine, silent is not" claim and should be read as a pair.
// Why: docs/concurrency.md#stall-watchdog
//
// This is the ONE file allowed to use wall-clock time — a timeout has no other observable.
// Why: docs/testing.md#the-wall-clock-exception

@Suite("Model download stall watchdog")
@MainActor
struct StallWatchdogTests {
    /// A short idle window and a fast poll, so the stalling tests resolve in ~100 ms.
    private static let idle: Duration = .milliseconds(100)
    private static let poll: Duration = .milliseconds(10)

    /// A deliberately roomier window for the one test that must NOT trip: 50× the tick interval.
    // This margin IS the flake budget: widen it (keeping the operation's runtime above it).
    // NEVER delete the test it protects to make a flake go away.
    // Why: docs/testing.md#the-flake-budget
    private static let tickingIdle: Duration = .seconds(1)

    /// The drain for tests whose operation honors cancellation and so unwinds immediately. Pure
    /// flake margin: it must not elapse ahead of an operation merely descheduled behind a
    /// contended main actor.
    private static let drain: Duration = .seconds(2)

    /// The opposite case, for `drainIsBounded` alone: comfortably SHORTER than that test's
    /// deliberately uncancellable operation (a detached 600-second sleep, i.e. one that effectively
    /// never finishes), or the drain would end early on `didFinish` and the bound go untested.
    private static let shortDrain: Duration = .milliseconds(200)

    @Test("An operation that finishes returns its value")
    func completedOperationReturnsValue() async throws {
        let ticker = ProgressTicker()
        let value = try await TranscriptionManager.withStallWatchdog(
            idle: Self.idle, poll: Self.poll, ticker: ticker
        ) {
            42
        }
        #expect(value == 42)
    }

    /// The point of the whole design: an operation can outlive the idle window many times over as
    /// long as it keeps reporting progress. A wall-clock deadline would have killed this one.
    @Test("A slow but progressing operation survives well past the idle window")
    func tickingOperationSurvivesPastIdleWindow() async throws {
        let ticker = ProgressTicker()
        let value = try await TranscriptionManager.withStallWatchdog(
            idle: Self.tickingIdle, poll: Self.poll, ticker: ticker, drain: Self.drain
        ) {
            // ~2 s of work: twice the idle window, in 20 ms steps. Runtime has to stay above
            // `tickingIdle` or this stops demonstrating survival past the window at all.
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(20))
                ticker.tick()
            }
            return 7
        }
        #expect(value == 7)
    }

    @Test("An operation that stops reporting progress is abandoned")
    func stallingOperationIsAbandoned() async {
        let ticker = ProgressTicker()
        await #expect(throws: StallTimeout(idle: Self.idle)) {
            try await TranscriptionManager.withStallWatchdog(
                idle: Self.idle, poll: Self.poll, ticker: ticker, drain: Self.drain
            ) {
                // Never ticks, never returns — the wedged download.
                try await Task.sleep(for: .seconds(3600))
                return 0
            }
        }
    }

    /// Abandoning is not enough: the orphaned work must be told to stop, and — because the error
    /// invites the user to retry immediately — it must have actually stopped before the caller
    /// hears about the failure. Otherwise the retry starts a second downloader writing the same
    /// partial file as an orphan that hasn't noticed cancellation yet. Asserting the flag WITHOUT
    /// waiting afterwards is the whole point: it can only be true if the drain held the failure
    /// back until the operation unwound. (`Self.drain` is wide for that reason — the operation
    /// unwinds the instant it is cancelled, so the width is margin against a contended main
    /// actor, not time this test spends.)
    @Test("The abandoned operation has stopped before the failure surfaces")
    func abandonedOperationIsDrained() async {
        let ticker = ProgressTicker()
        let cancelled = Mutex(false)

        await #expect(throws: StallTimeout(idle: Self.idle)) {
            try await TranscriptionManager.withStallWatchdog(
                idle: Self.idle, poll: Self.poll, ticker: ticker, drain: Self.drain
            ) {
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    // Unwind SLOWLY, and detached so an already-cancelled task can't skip the
                    // sleep. Without this the test proves nothing: main-actor FIFO ordering alone
                    // would run this `catch` before the continuation resumes, so the flag would be
                    // set even with the drain deleted. The delay is what makes the assertion
                    // below depend on the drain actually holding the failure back — verified by
                    // mutation: with `drain: .zero` this test fails.
                    await Task.detached { try? await Task.sleep(for: .milliseconds(150)) }.value
                    cancelled.withLock { $0 = true }
                    throw error
                }
                return 0
            }
        }

        #expect(cancelled.withLock { $0 })
    }

    /// The drain is a courtesy, not another way to hang. The operation effectively never finishes,
    /// which is the only way this tests the bound rather than a timing difference; the time limit
    /// turns "hangs forever" into a red run.
    /// Why: docs/testing.md#the-wall-clock-exception
    @Test(
        "An uncancellable operation is abandoned anyway once the drain elapses",
        .timeLimit(.minutes(1))
    )
    func drainIsBounded() async {
        let ticker = ProgressTicker()
        await #expect(throws: StallTimeout(idle: Self.idle)) {
            try await TranscriptionManager.withStallWatchdog(
                idle: Self.idle, poll: Self.poll, ticker: ticker, drain: Self.shortDrain
            ) {
                // Genuinely deaf to cancellation, which `try?` around `Task.sleep` is NOT: once
                // the task is cancelled every sleep fails instantly, so the operation would race
                // through and finish. A detached child doesn't inherit cancellation, so this
                // outlives the test itself — abandoned, exactly like a wedged download.
                await Task.detached { try? await Task.sleep(for: .seconds(600)) }.value
                return 0
            }
        }
    }

    @Test("An error thrown by the operation propagates unchanged")
    func operationErrorPropagates() async {
        let ticker = ProgressTicker()
        await #expect(throws: TranscriptionError.noAudioTrack) {
            try await TranscriptionManager.withStallWatchdog(
                idle: Self.idle, poll: Self.poll, ticker: ticker
            ) {
                throw TranscriptionError.noAudioTrack
            }
        }
    }

    /// The watchdog parks the caller on a continuation, so cancellation has to be forwarded
    /// explicitly — without this the caller would be stuck until the idle window elapsed.
    @Test("Cancelling the caller unblocks it")
    func cancellingCallerUnblocks() async {
        let ticker = ProgressTicker()
        let task = Task { @MainActor in
            await Task.yield()
            return try await TranscriptionManager.withStallWatchdog(
                idle: .seconds(3600), poll: Self.poll, ticker: ticker
            ) {
                try await Task.sleep(for: .seconds(3600))
                return 0
            }
        }
        // `Task.yield()` above suspends the task, so this synchronous cancel lands before the wait.
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("ProgressTicker")
struct ProgressTickerTests {
    @Test("Starts at zero and counts every tick")
    func countsTicks() {
        let ticker = ProgressTicker()
        #expect(ticker.count == 0)
        ticker.tick()
        ticker.tick()
        #expect(ticker.count == 2)
    }

    /// WhisperKit invokes its `ProgressCallback` off the main actor, from whatever context the Hub
    /// downloader happens to be on — so the counter has to be safe under concurrent ticks.
    @Test("Counts ticks from concurrent contexts")
    func countsConcurrentTicks() async {
        let ticker = ProgressTicker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { ticker.tick() }
            }
        }
        #expect(ticker.count == 100)
    }
}
