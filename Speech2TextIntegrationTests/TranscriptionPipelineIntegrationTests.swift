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
    .disabled(
        if: !whisperKitTestsEnabled,
        "Set TEST_RUNNER_RUN_WHISPERKIT_TESTS=1 to run — downloads the tiny model (~75 MB) on first use."
    )
)
struct TranscriptionPipelineIntegrationTests {

    @Test("Audio → text: tiny model transcribes synthesized speech")
    func audioToTextSucceeds() async throws {
        let speech = try await MediaFixtures.makeSpeechAudio()
        defer { MediaFixtures.cleanup([speech]) }

        let manager = TranscriptionManager()
        manager.selectedModel = .tiny
        manager.addFiles([speech])

        await manager.startTranscription()

        #expect(manager.status == .completed, "Status was \(manager.status)")
        #expect(!manager.transcriptionResult.isEmpty)
        assertContainsAnyExpectedKeyword(manager.transcriptionResult)
    }

    @Test("Video → text: full pipeline on a generated MP4")
    func videoToTextSucceeds() async throws {
        let speech = try await MediaFixtures.makeSpeechAudio()
        let video = try await MediaFixtures.makeVideoWithAudio(audioURL: speech, ext: "mp4")
        defer { MediaFixtures.cleanup([speech, video]) }

        let manager = TranscriptionManager()
        manager.selectedModel = .tiny
        manager.addFiles([video])

        await manager.startTranscription()

        #expect(manager.status == .completed, "Status was \(manager.status)")
        #expect(!manager.transcriptionResult.isEmpty)
        assertContainsAnyExpectedKeyword(manager.transcriptionResult)
    }

    @Test("Multi-file batch concatenates results with filename headers")
    func multiFileBatch() async throws {
        let first = try await MediaFixtures.makeSpeechAudio(text: "Hello there.")
        let second = try await MediaFixtures.makeSpeechAudio(text: "Testing one two three.")
        defer { MediaFixtures.cleanup([first, second]) }

        let manager = TranscriptionManager()
        manager.selectedModel = .tiny
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

        let manager = TranscriptionManager()
        manager.selectedModel = .tiny
        manager.selectedLanguage = .english
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

        let manager = TranscriptionManager()
        manager.selectedModel = .tiny
        manager.addFiles([speech])

        await manager.startTranscription()
        #expect(manager.status == .completed)
        let firstLoadedModel = manager.loadedModel
        #expect(firstLoadedModel == WhisperModel.tiny.rawValue)

        // Second run with same selected model — should not reset loadedModel.
        manager.addFiles([speech])
        await manager.startTranscription()
        #expect(manager.status == .completed)
        #expect(manager.loadedModel == firstLoadedModel)
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
