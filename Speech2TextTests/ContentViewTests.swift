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
@MainActor
@Suite("ContentView")
struct ContentViewTests {

    @Test("Transcribe is disabled when no files are selected")
    func transcribeDisabledWithNoFiles() throws {
        let manager = TranscriptionManager()
        let view = ContentView(manager: manager)

        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "transcribeButton")
        #expect(button.isDisabled() == true)
    }

    @Test("Transcribe is enabled once a supported file is added")
    func transcribeEnabledWithFiles() throws {
        let manager = TranscriptionManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/a.mp3")])
        let view = ContentView(manager: manager)

        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "transcribeButton")
        #expect(button.isDisabled() == false)
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
        // One supported file keeps the list non-empty; the unsupported one is
        // reported via skippedFileNames and rendered in the warning row.
        manager.addFiles([
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/notes.pdf"),
        ])
        let view = ContentView(manager: manager)

        let warning = try view.inspect().find(viewWithAccessibilityIdentifier: "skippedWarning")
        #expect(try warning.text().string() == "Unsupported file skipped: notes.pdf")
    }

    @Test("Status text reflects the manager's status message")
    func statusTextReflectsManager() throws {
        let manager = TranscriptionManager()
        manager.status = .completed
        let view = ContentView(manager: manager)

        let status = try view.inspect().find(viewWithAccessibilityIdentifier: "statusText")
        #expect(try status.text().string() == "Transcription complete")
    }
}
