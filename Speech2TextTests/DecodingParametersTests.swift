import Foundation
import Testing
import WhisperKit

@testable import Speech2Text

// MARK: - Decoding Parameters

/// Covers the user-facing decoding knobs (task, temperature) and the state→`DecodingOptions`
/// mapping in `makeDecodingOptions()`. This is the pure logic that's testable without loading a
/// model or hitting the network; the actual `transcribe(...)` call is not exercised here.
@MainActor
@Suite("Decoding parameters")
struct DecodingParametersTests {

    // MARK: Defaults

    @Test("Defaults to Transcribe, temperature 0")
    func defaults() {
        let manager = TranscriptionManager()
        #expect(manager.selectedTask == .transcribe)
        #expect(manager.temperature == 0.0)
    }

    // MARK: Task display names

    @Test("Task display names are the expected user-facing labels")
    func taskDisplayNames() {
        #expect(DecodingTask.transcribe.displayName == "Transcribe")
        #expect(DecodingTask.translate.displayName == "Translate to English")
    }

    @Test("Every DecodingTask case has a non-empty display name")
    func allTaskDisplayNamesNonEmpty() {
        for task in DecodingTask.allCases {
            #expect(!task.displayName.isEmpty)
        }
    }

    // MARK: makeDecodingOptions mapping

    @Test("Options carry the selected task and temperature")
    func optionsCarryTaskAndTemperature() {
        let manager = TranscriptionManager()
        manager.selectedTask = .translate
        manager.temperature = 0.4

        let options = manager.makeDecodingOptions()
        #expect(options.task == .translate)
        #expect(options.temperature == 0.4)
    }

    @Test("VAD chunking is always applied")
    func vadChunkingAlwaysApplied() {
        let manager = TranscriptionManager()
        #expect(manager.makeDecodingOptions().chunkingStrategy == .vad)
    }

    @Test("Auto-detect leaves language nil for WhisperKit to detect")
    func autoLeavesLanguageNil() {
        let manager = TranscriptionManager()
        manager.selectedLanguage = .auto
        #expect(manager.makeDecodingOptions().language == nil)
    }

    @Test("A specific language is projected onto options.language")
    func specificLanguageIsProjected() {
        let manager = TranscriptionManager()
        // Pick any real non-auto entry from the mirrored list.
        guard let spanish = TranscriptionLanguage.allCases.first(where: { $0.code == "es" }) else {
            Issue.record("Expected a Spanish entry in the language list")
            return
        }
        manager.selectedLanguage = spanish
        #expect(manager.makeDecodingOptions().language == "es")
    }
}
