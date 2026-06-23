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

    @Test("Transcribe is disabled when no files are selected")
    func transcribeDisabledWithNoFiles() throws {
        let manager = TranscriptionManager()
        let view = ContentView(manager: manager)

        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "transcribeButton")
        #expect(button.isDisabled())
    }

    @Test("Transcribe is enabled once a supported file is added")
    func transcribeEnabledWithFiles() throws {
        let manager = TranscriptionManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/a.mp3")])
        let view = ContentView(manager: manager)

        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "transcribeButton")
        #expect(!button.isDisabled())
    }

    @Test("The file list renders one entry per added file")
    func fileListRendersEntryPerFile() throws {
        let manager = TranscriptionManager()
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
        let manager = TranscriptionManager()
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
        let manager = TranscriptionManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/notes.pdf")])
        let view = ContentView(manager: manager)

        let warning = try view.inspect().find(viewWithAccessibilityIdentifier: "skippedWarning")
        #expect(try warning.text().string() == "Unsupported file skipped: notes.pdf")
    }

    @Test("Status text reflects the manager's status message")
    func statusTextReflectsManager() throws {
        let manager = TranscriptionManager()
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
        let manager = TranscriptionManager()
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
        let manager = TranscriptionManager()
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
        let manager = TranscriptionManager()
        let view = ContentView(manager: manager)

        let label = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "languagePicker")
            .button().labelView().hStack().text(0).string()
        #expect(label == "Auto-detect")
    }
}
