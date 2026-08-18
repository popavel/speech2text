import Foundation
import Testing
import ViewInspector

@testable import Speech2Text

// View-render tests for ContentView. These assert that the SwiftUI hierarchy
// reflects the injected TranscriptionManager's state — they do NOT exercise the
// manager's behavior (that lives in TranscriptionManagerTests) and never tap
// Transcribe (which would load WhisperKit). All inspection is static: we read
// the rendered body of a freshly built view, so no ViewHosting / XCTest
// machinery is needed and the suite stays pure Swift Testing.
//
// Assertion-style convention: use bare `try` when the found view's value is then
// asserted (the result is bound and used); use `#expect(throws: Never.self) { ... }`
// for existence-only checks, where the result is discarded — it documents the
// "this lookup must succeed" intent and avoids an unused-result warning.
@MainActor
@Suite("ContentView")
struct ContentViewTests {

    /// A per-test fixture (fresh ephemeral `UserDefaults`, cleaned up when the test's suite instance
    /// is released): a couple of these tests read/write settings (`selectedLanguage`), so keep them
    /// off `.standard` and isolated from one another. See `ManagerFixture` in `Speech2TextTestSupport`.
    private let fixture = ManagerFixture()
    private func makeManager() -> TranscriptionManager {
        fixture.makeManager()
    }

    @Test("Transcribe is disabled when no files are selected")
    func transcribeDisabledWithNoFiles() throws {
        let manager = makeManager()
        let view = ContentView(manager: manager)

        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "transcribeButton")
        #expect(button.isDisabled())
    }

    @Test("Transcribe is enabled once a supported file is added")
    func transcribeEnabledWithFiles() throws {
        let manager = makeManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/a.mp3")])
        let view = ContentView(manager: manager)

        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "transcribeButton")
        #expect(!button.isDisabled())
    }

    @Test("The file list renders one entry per added file")
    func fileListRendersEntryPerFile() throws {
        let manager = makeManager()
        manager.addFiles([
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.wav"),
        ])
        let view = ContentView(manager: manager)

        // The header reports the count, and each file renders its own name chip.
        #expect(throws: Never.self) { try view.inspect().find(text: "2 file(s) selected") }
        #expect(throws: Never.self) { try view.inspect().find(text: "a.mp3") }
        #expect(throws: Never.self) { try view.inspect().find(text: "b.wav") }
    }

    @Test("A skipped unsupported file surfaces the warning row")
    func skippedFilesWarningAppears() throws {
        let manager = makeManager()
        // Both files are added together; only the unsupported one lands in
        // skippedFileNames and triggers the warning row. The warning gates on
        // skippedFileNames alone — it does not depend on a non-empty fileList.
        manager.addFiles([
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/notes.pdf"),
        ])
        let view = ContentView(manager: manager)

        let warning = try view.inspect().find(viewWithAccessibilityIdentifier: "skippedWarning")
        #expect(try warning.text().string() == "Unsupported file skipped: notes.pdf")
    }

    @Test("Warning row appears when no valid files are queued")
    func warningAppearsWithOnlySkippedFile() throws {
        // Only an unsupported file is dropped, so droppedFileURLs stays empty. The
        // warning still renders, proving it gates on skippedFileNames alone and not
        // on a non-empty fileList (ContentView.swift:43 vs :31).
        let manager = makeManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/notes.pdf")])
        let view = ContentView(manager: manager)

        let warning = try view.inspect().find(viewWithAccessibilityIdentifier: "skippedWarning")
        #expect(try warning.text().string() == "Unsupported file skipped: notes.pdf")
    }

    @Test("Status text reflects the manager's status message")
    func statusTextReflectsManager() throws {
        let manager = makeManager()
        manager.status = .completed
        let view = ContentView(manager: manager)

        // Derive the expected text from the manager rather than duplicating the
        // literal: this render test asserts the view shows exactly what the manager
        // reports. The "Transcription complete" copy itself is pinned in the
        // manager's own unit tests.
        let status = try view.inspect().find(viewWithAccessibilityIdentifier: "statusText")
        #expect(try status.text().string() == manager.statusMessage)
    }

    @Test("Each file chip exposes a uniquely indexed remove button")
    func fileChipsHaveIndexedRemoveButtons() throws {
        let manager = makeManager()
        manager.addFiles([
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.wav"),
        ])
        let view = ContentView(manager: manager)

        // Per-row identifiers must be unique so an XCUITest can address a single
        // chip's remove button without a "multiple matching elements" failure.
        #expect(throws: Never.self) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "removeFileButton-0")
        }
        #expect(throws: Never.self) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "removeFileButton-1")
        }
    }

    @Test("The language picker button renders the manager's selected language")
    func languagePickerReflectsSelection() throws {
        let manager = makeManager()
        manager.selectedLanguage = .english
        let view = ContentView(manager: manager)

        // Read the button's own label text — not a global find — so the assertion is
        // about the collapsed picker, never the popover list (which only materializes
        // at runtime when presented; that flow is covered in Speech2TextUITests).
        let label = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "languagePicker")
            .button().labelView().hStack().text(0).string()
        #expect(label == "English")
    }

    @Test("The language picker button defaults to Auto-detect")
    func languagePickerDefaultsToAuto() throws {
        let manager = makeManager()
        let view = ContentView(manager: manager)

        let label = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "languagePicker")
            .button().labelView().hStack().text(0).string()
        #expect(label == "Auto-detect")
    }
}

// Render tests for the Settings scene's Storage controls. Static inspection only, like the
// ContentView suite above — never taps the destructive buttons (which would touch the filesystem).
@MainActor
@Suite("SettingsView")
struct SettingsViewTests {
    private let fixture = ManagerFixture()
    private func makeManager() -> TranscriptionManager { fixture.makeManager() }

    @Test("Remove All App Data is enabled at rest")
    func removeAllDataEnabledAtRest() throws {
        let view = SettingsView(manager: makeManager(), updater: FakeUpdater())
        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "removeAllDataButton")
        // Unlike Delete Downloaded Models, the wipe isn't gated on a non-empty cache: settings
        // persist even with no models, so it must stay available.
        #expect(!button.isDisabled())
    }

    @Test("Remove All App Data is disabled while a transcription is running")
    func removeAllDataDisabledWhileProcessing() throws {
        let manager = makeManager()
        manager.status = .transcribing(progress: 0.5)
        let view = SettingsView(manager: manager, updater: FakeUpdater())
        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "removeAllDataButton")
        #expect(button.isDisabled())
    }

    @Test("The auto-update toggle is live when an updater is driving it")
    func autoUpdateToggleEnabledWhenActive() throws {
        let view = SettingsView(manager: makeManager(), updater: FakeUpdater(isActive: true))
        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "automaticUpdatesToggle")
        #expect(!toggle.isDisabled())
    }

    @Test("The auto-update toggle is disabled in a gated (development) build")
    func autoUpdateToggleDisabledWhenInactive() throws {
        // Gated processes have no updater behind the toggle, so a write would be silently dropped
        // on the next launch — the control must not look live.
        let view = SettingsView(manager: makeManager(), updater: FakeUpdater(isActive: false))
        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "automaticUpdatesToggle")
        #expect(toggle.isDisabled())
        #expect(try captionText(of: view).contains("disabled in development builds"))
    }

    @Test("The Updates caption stops promising a daily check once auto-checks are off")
    func updatesCaptionTracksTheToggle() throws {
        let on = SettingsView(
            manager: makeManager(),
            updater: FakeUpdater(automaticallyChecksForUpdates: true)
        )
        #expect(try captionText(of: on).contains("about once a day"))

        // The caption must follow the toggle, not just `isActive` — otherwise it keeps claiming a
        // daily check the user has switched off.
        let off = SettingsView(
            manager: makeManager(),
            updater: FakeUpdater(automaticallyChecksForUpdates: false)
        )
        #expect(try captionText(of: off).contains("Automatic checks are off"))
    }

    @Test("Flipping the auto-update toggle writes back to the updater")
    func autoUpdateToggleWritesThrough() throws {
        // The Binding's `set` half is the only path that persists the user's opt-out. Without
        // this, gutting it leaves every other test green while the preference silently never
        // sticks — the same class of regression the model's write-through test guards.
        let updater = FakeUpdater(automaticallyChecksForUpdates: true)
        let view = SettingsView(manager: makeManager(), updater: updater)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: "automaticUpdatesToggle")
            .toggle()
            .tap()

        #expect(!updater.automaticallyChecksForUpdates)
    }

    private func captionText(of view: SettingsView) throws -> String {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: "updatesCaption")
            .text()
            .string()
    }
}
