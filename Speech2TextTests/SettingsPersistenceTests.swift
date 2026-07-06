import Foundation
import Testing
import WhisperKit

@testable import Speech2Text

// MARK: - Test support

/// A throwaway `UserDefaults` domain, unique per call, for exercising `TranscriptionManager`'s
/// settings persistence in isolation. The unit-test host runs under the app's own bundle id, so
/// persisting to `.standard` would read/write the user's real settings and let one test's writes
/// bleed into the next; an ephemeral suite (cleared on creation) keeps each test hermetic. Shared
/// across the settings-touching suites — a top-level (module-internal) helper visible target-wide.
func makeEphemeralDefaults() -> UserDefaults {
    let suiteName = "s2t.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

// MARK: - Settings persistence

/// Covers persistence of the four user settings (task, language, model, temperature) across
/// `TranscriptionManager` instances that share a store, plus `restoreDefaults()`. Every manager is
/// built on an injected ephemeral `UserDefaults`, so nothing here touches `.standard`.
@MainActor
@Suite("Settings persistence")
struct SettingsPersistenceTests {

    /// A non-auto language guaranteed to exist in WhisperKit's mirrored list. Resolved with the
    /// same `first { code == "es" }` predicate `loadPersistedSettings` uses, so a persisted "es"
    /// round-trips back to this exact entry regardless of alias ordering.
    private func spanishLanguage() -> TranscriptionLanguage? {
        TranscriptionLanguage.allCases.first { $0.code == "es" }
    }

    @Test("A fresh store yields the code defaults")
    func freshStoreUsesDefaults() {
        let manager = TranscriptionManager(defaults: makeEphemeralDefaults())
        #expect(manager.selectedTask == .transcribe)
        #expect(manager.selectedModel == .base)
        #expect(manager.temperature == 0.0)
        #expect(manager.selectedLanguage == .auto)
    }

    @Test("Settings round-trip across manager instances sharing a store")
    func settingsRoundTrip() throws {
        let defaults = makeEphemeralDefaults()
        let spanish = try #require(spanishLanguage())

        let first = TranscriptionManager(defaults: defaults)
        first.selectedTask = .translate
        first.selectedModel = .small
        first.temperature = 0.4
        first.selectedLanguage = spanish

        let second = TranscriptionManager(defaults: defaults)
        #expect(second.selectedTask == .translate)
        #expect(second.selectedModel == .small)
        #expect(second.temperature == 0.4)
        #expect(second.selectedLanguage.code == "es")
    }

    @Test("restoreDefaults resets all four settings")
    func restoreDefaultsResets() throws {
        let manager = TranscriptionManager(defaults: makeEphemeralDefaults())
        manager.selectedTask = .translate
        manager.selectedModel = .largeV3
        manager.temperature = 0.6
        manager.selectedLanguage = try #require(spanishLanguage())

        manager.restoreDefaults()

        #expect(manager.selectedTask == .transcribe)
        #expect(manager.selectedModel == .base)
        #expect(manager.temperature == 0.0)
        #expect(manager.selectedLanguage == .auto)
    }

    @Test("restoreDefaults is itself persisted")
    func restoreDefaultsPersists() {
        let defaults = makeEphemeralDefaults()
        let first = TranscriptionManager(defaults: defaults)
        first.selectedModel = .small
        first.selectedTask = .translate
        first.restoreDefaults()

        let second = TranscriptionManager(defaults: defaults)
        #expect(second.selectedModel == .base)
        #expect(second.selectedTask == .transcribe)
    }

    @Test("An unknown persisted model id falls back to the default")
    func invalidModelFallsBack() {
        let defaults = makeEphemeralDefaults()
        defaults.set("openai_whisper-does-not-exist", forKey: TranscriptionManager.Keys.model)

        let manager = TranscriptionManager(defaults: defaults)
        #expect(manager.selectedModel == .base)
    }

    @Test("An unlisted persisted language code falls back to Auto-detect")
    func unknownLanguageFallsBack() {
        let defaults = makeEphemeralDefaults()
        defaults.set("zz-not-a-language", forKey: TranscriptionManager.Keys.language)

        let manager = TranscriptionManager(defaults: defaults)
        #expect(manager.selectedLanguage == .auto)
    }

    @Test("A UI-test launch persists to an isolated store, not .standard")
    func uiTestStoreIsIsolatedFromStandard() {
        // No flag → the real app persists to `.standard`.
        #expect(TranscriptionManager.uiTestSettingsStore(arguments: []) === UserDefaults.standard)

        // `-uiTesting` → a separate, cleared store, so a manager on it always starts from the code
        // defaults (regardless of what the real app previously saved) and nothing bleeds into
        // `.standard`. This is what keeps `testLanguagePickerSearchAndSelect` deterministic.
        let store = TranscriptionManager.uiTestSettingsStore(arguments: ["-uiTesting"])
        #expect(store !== UserDefaults.standard)

        let manager = TranscriptionManager(defaults: store)
        #expect(manager.selectedLanguage == .auto)
        #expect(manager.selectedModel == .base)
        #expect(manager.selectedTask == .transcribe)
        #expect(manager.temperature == 0.0)
    }
}
