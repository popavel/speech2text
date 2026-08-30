import Foundation
import Testing

@testable import Speech2Text

// Drives `TranscriptionManager.startTranscription()` end-to-end with real
// WhisperKit. Gated because the `tiny` model (~75 MB) is downloaded over the
// network on first use. xcodebuild forwards env vars prefixed `TEST_RUNNER_`
// to the test process with the prefix stripped; the plain `RUN_WHISPERKIT_TESTS`
// form works when running tests directly (not through xcodebuild).

private let whisperKitTestsEnabled: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["RUN_WHISPERKIT_TESTS"] == "1"
        || env["TEST_RUNNER_RUN_WHISPERKIT_TESTS"] == "1"
}()

@MainActor
@Suite(
    "Transcription pipeline (integration)",
    // Run serially: every test loads a WhisperKit model into the same shared model
    // cache (`TranscriptionManager.modelCacheDirectory`, NOT WhisperKit's default
    // ~/Documents/huggingface — `downloadBase` overrides it), so concurrent first-run
    // downloads would race on the same files. (parallelizable="NO" in the scheme only
    // governs XCTest's multi-process runner, not Swift Testing's in-process parallelism.)
    .serialized,
    .disabled(
        if: !whisperKitTestsEnabled,
        "Set TEST_RUNNER_RUN_WHISPERKIT_TESTS=1 to run — downloads the tiny model (~75 MB) on first use."
    )
)
struct TranscriptionPipelineIntegrationTests {

    // Shared across the tests below so the ~75 MB tiny model is loaded into
    // memory once for the whole (serialized) suite instead of once per test.
    // `modelCachingAcrossRuns` deliberately uses its own fresh manager because
    // it asserts first-load-then-reuse behavior.
    //
    // Built on a `ManagerFixture` (ephemeral store), NOT `TranscriptionManager()`: this target is
    // app-hosted, so `.standard` is the app's real `com.speech2text.app` domain — the `.tiny`/
    // language writes below would otherwise clobber the developer's saved settings when the suite
    // runs. The fixture is a process-lifetime `static`, so its store outlives every write here; it
    // is released only at process exit, leaving a single ephemeral `s2t.test.*` domain (never
    // `.standard`) — an acceptable residue for this opt-in suite.
    private static let sharedFixture = ManagerFixture()
    private static let sharedManager = sharedFixture.makeManager()

    private static func preparedManager(
        language: TranscriptionLanguage = .auto
    ) -> TranscriptionManager {
        let manager = sharedManager
        manager.clearFiles()
        manager.selectedModel = .tiny
        manager.selectedLanguage = language
        return manager
    }

    @Test("Audio → text: tiny model transcribes synthesized speech")
    func audioToTextSucceeds() async throws {
        let speech = try await MediaFixtures.makeSpeechAudio()
        defer { MediaFixtures.cleanup([speech]) }

        let manager = Self.preparedManager()
        manager.addFiles([speech])

        await manager.startTranscription()

        #expect(manager.status == .completed, "Status was \(manager.status)")
        #expect(!manager.transcriptionResult.isEmpty)
        assertContainsAnyExpectedKeyword(manager.transcriptionResult)
    }

    @Test("Video → text: full pipeline on a generated MP4")
    func videoToTextSucceeds() async throws {
        let speech = try await MediaFixtures.makeSpeechAudio()
        defer { MediaFixtures.cleanup([speech]) }
        let video = try await MediaFixtures.makeVideoWithAudio(audioURL: speech, ext: "mp4")
        defer { MediaFixtures.cleanup([video]) }

        let manager = Self.preparedManager()
        manager.addFiles([video])

        await manager.startTranscription()

        #expect(manager.status == .completed, "Status was \(manager.status)")
        #expect(!manager.transcriptionResult.isEmpty)
        assertContainsAnyExpectedKeyword(manager.transcriptionResult)
    }

    @Test("Multi-file batch concatenates results with filename headers")
    func multiFileBatch() async throws {
        let first = try await MediaFixtures.makeSpeechAudio(text: "Hello there.")
        defer { MediaFixtures.cleanup([first]) }
        let second = try await MediaFixtures.makeSpeechAudio(text: "Testing one two three.")
        defer { MediaFixtures.cleanup([second]) }

        let manager = Self.preparedManager()
        manager.addFiles([first, second])

        await manager.startTranscription()

        #expect(manager.status == .completed, "Status was \(manager.status)")
        #expect(manager.transcriptionResult.contains("--- \(first.lastPathComponent) ---"))
        #expect(manager.transcriptionResult.contains("--- \(second.lastPathComponent) ---"))
    }

    @Test("Language override completes without error")
    func languageOverride() async throws {
        let speech = try await MediaFixtures.makeSpeechAudio()
        defer { MediaFixtures.cleanup([speech]) }

        let manager = Self.preparedManager(language: .english)
        manager.addFiles([speech])

        await manager.startTranscription()

        #expect(manager.status == .completed, "Status was \(manager.status)")
        #expect(!manager.transcriptionResult.isEmpty)
        assertContainsAnyExpectedKeyword(manager.transcriptionResult)
    }

    @Test("Same-model reload reuses the loaded WhisperKit instance")
    func modelCachingAcrossRuns() async throws {
        let speech = try await MediaFixtures.makeSpeechAudio(text: "Hello.")
        defer { MediaFixtures.cleanup([speech]) }

        // Fresh manager (not the shared one) so the first run is a genuine load. On its own
        // ephemeral fixture — held for the whole test — so it neither loads nor clobbers `.standard`.
        let fixture = ManagerFixture()
        let manager = fixture.makeManager()
        manager.selectedModel = .tiny
        manager.addFiles([speech])

        await manager.startTranscription()
        #expect(manager.status == .completed)
        #expect(manager.loadedModel == WhisperModel.tiny.rawValue)
        // The first run actually constructs an instance.
        let firstInstance = manager.loadedModelInstance
        #expect(firstInstance != nil)

        // Second run with the same selected model must reuse that very instance
        // rather than reconstruct it.
        manager.addFiles([speech])
        await manager.startTranscription()
        #expect(manager.status == .completed)
        #expect(manager.loadedModelInstance === firstInstance)
    }

    // MARK: Helpers

    private func assertContainsAnyExpectedKeyword(
        _ text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let lower = text.lowercased()
        let hit = MediaFixtures.defaultSpeechKeywords.contains { lower.contains($0) }
        #expect(
            hit,
            "Transcription did not contain any expected keyword. Got: \(text)",
            sourceLocation: sourceLocation
        )
    }
}
