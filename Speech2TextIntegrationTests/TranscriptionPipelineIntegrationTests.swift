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
    // Run serially: every test loads a WhisperKit model into the same shared
    // ~/Documents/huggingface cache, so concurrent first-run downloads would
    // race on the same files. (parallelizable="NO" in the scheme only governs
    // XCTest's multi-process runner, not Swift Testing's in-process parallelism.)
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
    private static let sharedManager = TranscriptionManager()

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

        // Fresh manager (not the shared one) so the first run is a genuine load.
        let manager = TranscriptionManager()
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
