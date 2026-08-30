import Foundation
import Testing
import WhisperKit

@testable import Speech2Text

// MARK: - Settings persistence

/// Covers persistence of the four user settings (task, language, model, temperature) across
/// `TranscriptionManager` instances that share a store, plus `restoreDefaults()`. Every manager is
/// built from a `ManagerFixture` (an injected, self-clearing ephemeral `UserDefaults`), so nothing
/// here touches `.standard`. See `ManagerFixture` in `Speech2TextTestSupport`.
@MainActor
@Suite("Settings persistence")
struct SettingsPersistenceTests {

    /// A non-auto language guaranteed to exist in WhisperKit's mirrored list, looked up by `code`
    /// so the test doesn't hard-code a display name. Persistence itself round-trips the entry's
    /// `id` (its `displayName`), not its code — see `loadPersistedSettings`.
    private func spanishLanguage() -> TranscriptionLanguage? {
        TranscriptionLanguage.allCases.first { $0.code == "es" }
    }

    @Test("A fresh store yields the code defaults")
    func freshStoreUsesDefaults() {
        let fixture = ManagerFixture()
        let manager = fixture.makeManager()
        #expect(manager.selectedTask == .transcribe)
        #expect(manager.selectedModel == .base)
        #expect(manager.temperature == 0.0)
        #expect(manager.selectedLanguage == .auto)
    }

    @Test("Settings round-trip across manager instances sharing a store")
    func settingsRoundTrip() throws {
        let fixture = ManagerFixture()
        let spanish = try #require(spanishLanguage())

        let first = fixture.makeManager()
        first.selectedTask = .translate
        first.selectedModel = .small
        first.temperature = 0.4
        first.selectedLanguage = spanish

        let second = fixture.makeManager()
        #expect(second.selectedTask == .translate)
        #expect(second.selectedModel == .small)
        #expect(second.temperature == 0.4)
        #expect(second.selectedLanguage == spanish)
    }

    @Test("Aliases that share a code round-trip to their exact row")
    func aliasRoundTripsToExactRow() throws {
        // WhisperKit lists alias names that map to one code (e.g. Mandarin/Chinese → "zh") as
        // separate rows. Take one such code's rows and prove each restores to *itself*, not to
        // whichever alias happens to sort first for that code.
        let byCode = Dictionary(
            grouping: TranscriptionLanguage.allCases.filter { $0 != .auto },
            by: { $0.code }
        )
        let aliases = try #require(byCode.values.first { $0.count >= 2 })

        for row in aliases {
            let fixture = ManagerFixture()
            fixture.makeManager().selectedLanguage = row

            let restored = fixture.makeManager().selectedLanguage
            #expect(restored == row)
        }
    }

    @Test("restoreDefaults resets all four settings")
    func restoreDefaultsResets() throws {
        let fixture = ManagerFixture()
        let manager = fixture.makeManager()
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
        let fixture = ManagerFixture()
        let first = fixture.makeManager()
        first.selectedModel = .small
        first.selectedTask = .translate
        first.restoreDefaults()

        let second = fixture.makeManager()
        #expect(second.selectedModel == .base)
        #expect(second.selectedTask == .transcribe)
    }

    @Test("An unknown persisted model id falls back to the default")
    func invalidModelFallsBack() {
        let fixture = ManagerFixture()
        fixture.defaults.set("openai_whisper-does-not-exist", forKey: TranscriptionManager.Keys.model)

        let manager = fixture.makeManager()
        #expect(manager.selectedModel == .base)
    }

    @Test("An unlisted persisted language code falls back to Auto-detect")
    func unknownLanguageFallsBack() {
        let fixture = ManagerFixture()
        fixture.defaults.set("zz-not-a-language", forKey: TranscriptionManager.Keys.language)

        let manager = fixture.makeManager()
        #expect(manager.selectedLanguage == .auto)
    }

    @Test("An unresolvable stored language is preserved on disk, not erased on launch")
    func unresolvableLanguageIsPreserved() {
        // A language id that resolved under an earlier WhisperKit but no longer matches any row must
        // not be destroyed merely by launching: the in-memory value falls back to the default, but
        // the stored id stays put so it resolves again if that entry returns. Mirrors the model path
        // (which likewise preserves an unavailable stored id). Would fail before the load path
        // stopped writing `.auto` back over an unresolved language.
        let fixture = ManagerFixture()
        let staleID = "Faroese-was-valid-once"
        fixture.defaults.set(staleID, forKey: TranscriptionManager.Keys.language)

        let manager = fixture.makeManager()
        #expect(manager.selectedLanguage == .auto)
        #expect(fixture.defaults.string(forKey: TranscriptionManager.Keys.language) == staleID)
    }

    @Test("A UI-test launch persists to an isolated store, not .standard")
    func uiTestStoreIsIsolatedFromStandard() {
        // No flag → the real app persists to `.standard`.
        #expect(TranscriptionManager.uiTestSettingsStore(arguments: []) === UserDefaults.standard)

        // `-uiTesting` → a separate, cleared store, so a manager on it always starts from the code
        // defaults (regardless of what the real app previously saved) and nothing bleeds into
        // `.standard`. This is what keeps `testLanguagePickerSearchAndSelect` deterministic.
        let store = TranscriptionManager.uiTestSettingsStore(
            arguments: [TranscriptionManager.uiTestingLaunchArgument]
        )
        #expect(store !== UserDefaults.standard)

        let manager = TranscriptionManager(defaults: store)
        #expect(manager.selectedLanguage == .auto)
        #expect(manager.selectedModel == .base)
        #expect(manager.selectedTask == .transcribe)
        #expect(manager.temperature == 0.0)
    }
}
