import XCTest

/// End-to-end UI automation that launches the real app and drives its controls.
///
/// XCUIApplication lives in XCTest, so this target is the deliberate exception
/// to the repo's Swift Testing convention (documented in AGENTS.md).
///
/// These tests rely on the `#if DEBUG` launch seam in TranscriptionManager:
/// `-uiTesting` plus `UITEST_PRELOAD_FILES` / `UITEST_STUB_RESULT` seed state
/// without a file dialog, drag-and-drop, or loading WhisperKit. They never tap
/// Transcribe — that would download a model.
///
/// `@MainActor` on the class keeps XCUIApplication's main-actor-isolated members
/// reachable; values are read into locals before XCTAssert so they aren't touched
/// from XCTAssert's nonisolated autoclosure (Swift 6 strict concurrency).
@MainActor
final class Speech2TextUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Wait for `element` to register in the accessibility tree, then assert it did.
    /// `waitForExistence` returns immediately if the element is already present, so
    /// this is also safe for siblings that render in the same body update.
    private func assertExists(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        _ message: String = ""
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            message.isEmpty ? "\(element) did not appear within \(timeout)s" : message
        )
    }

    private func launchApp(
        preloadFiles: [String] = [],
        stubResult: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        // Sentinel consumed by TranscriptionManager.applyUITestSeamIfPresent(); the
        // string must match the guard there (Speech2Text/TranscriptionManager.swift).
        app.launchArguments = ["-uiTesting"]
        if !preloadFiles.isEmpty {
            app.launchEnvironment["UITEST_PRELOAD_FILES"] = preloadFiles.joined(separator: "\n")
        }
        if let stubResult {
            app.launchEnvironment["UITEST_STUB_RESULT"] = stubResult
        }
        app.launch()
        return app
    }

    func testTranscribeDisabledOnLaunchWithNoFiles() {
        let app = launchApp()
        let transcribe = app.buttons["transcribeButton"]
        assertExists(transcribe, timeout: 10)
        let isEnabled = transcribe.isEnabled
        XCTAssertFalse(isEnabled)
    }

    func testPreloadedFilesEnableTranscribe() {
        let app = launchApp(preloadFiles: ["/tmp/a.mp3", "/tmp/b.wav"])
        let transcribe = app.buttons["transcribeButton"]
        assertExists(transcribe, timeout: 10)
        let isEnabled = transcribe.isEnabled
        XCTAssertTrue(isEnabled)
        // Verify the count two ways. First, exactly two files are queued —
        // asserted via the per-chip remove buttons, which is independent of the
        // count label's display string (so a wording/format change can't mask a
        // wrong count).
        assertExists(app.buttons["removeFileButton-0"])
        assertExists(app.buttons["removeFileButton-1"])
        XCTAssertFalse(app.buttons["removeFileButton-2"].exists)
        // Second, the count label renders the total. On macOS a SwiftUI `Text`
        // surfaces its string under the accessibility `value`, not `label` (which
        // is empty), so read `.value`.
        let countLabel = app.staticTexts["fileCountLabel"]
        assertExists(countLabel)
        let countLabelValue = countLabel.value as? String
        XCTAssertEqual(countLabelValue, "2 file(s) selected")
    }

    func testStubbedResultShowsResultUI() {
        let app = launchApp(preloadFiles: ["/tmp/a.mp3"], stubResult: "hello world")
        // The result editor and its actions appear only once there's a result —
        // the stub seam sets status = .completed without running WhisperKit.
        let editor = app.textViews["resultTextEditor"]
        assertExists(editor, timeout: 10)
        // Assert the rendered transcription, not just the editor's presence: a wrong
        // stub value (encoding change, key rename, a double seam call) would still
        // render the result section and pass every existence check otherwise.
        let editorValue = editor.value as? String
        XCTAssertEqual(editorValue, "hello world")
        // Wait on each sibling rather than a bare `.exists`: they render in the same
        // body update as the editor, but the a11y tree may not have settled yet on a
        // loaded CI runner. waitForExistence returns immediately if already present.
        assertExists(app.buttons["copyButton"])
        assertExists(app.buttons["exportButton"])
        // Assert the status message too, not just its presence: for .completed the
        // text is "Transcription complete", so a regression to that string would
        // otherwise pass on existence alone. Read `.value` (Text surfaces its string
        // there on macOS, not `.label`) — same as fileCountLabel above.
        let statusText = app.staticTexts["statusText"]
        assertExists(statusText)
        let statusTextValue = statusText.value as? String
        XCTAssertEqual(statusTextValue, "Transcription complete")
        // Intentionally do NOT tap transcribeButton — it would load a model.
    }

    func testLanguagePickerSearchAndSelect() {
        // The picker is always visible — no preloaded files or stub result needed.
        let app = launchApp()
        let picker = app.buttons["languagePicker"]
        assertExists(picker, timeout: 10)
        // Defaults to Auto-detect; the value carries the selection (see accessibilityValue).
        XCTAssertEqual(picker.value as? String, "Auto-detect")

        // Open the popover → the search field appears.
        picker.click()
        let search = app.textFields["languageSearchField"]
        assertExists(search)

        // Filter to "German". The filter ran iff the unfiltered "Auto-detect" row drops
        // out, so wait for its removal (the re-render is async) — that wait is the real
        // proof, and it's what makes the subsequent German assertion meaningful (German
        // is in the unfiltered list too, so on its own it would prove nothing).
        search.click()
        search.typeText("German")
        XCTAssertTrue(
            app.buttons["languageOption-Auto-detect"].waitForNonExistence(timeout: 5),
            "Filter did not remove the Auto-detect row"
        )
        assertExists(app.buttons["languageOption-German"])

        // Select it → the popover dismisses and the picker reflects the choice. The
        // accessibilityValue updates on the next render after selection, so poll for it
        // rather than reading a possibly-stale snapshot.
        app.buttons["languageOption-German"].click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "German"), evaluatedWith: picker)
        waitForExpectations(timeout: 5)
    }
}
