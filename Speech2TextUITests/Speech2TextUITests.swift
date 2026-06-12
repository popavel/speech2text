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

    private func launchApp(
        preloadFiles: [String] = [],
        stubResult: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
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
        let exists = transcribe.waitForExistence(timeout: 10)
        XCTAssertTrue(exists)
        let isEnabled = transcribe.isEnabled
        XCTAssertFalse(isEnabled)
    }

    func testPreloadedFilesEnableTranscribe() {
        let app = launchApp(preloadFiles: ["/tmp/a.mp3", "/tmp/b.wav"])
        let transcribe = app.buttons["transcribeButton"]
        let exists = transcribe.waitForExistence(timeout: 10)
        XCTAssertTrue(exists)
        let isEnabled = transcribe.isEnabled
        XCTAssertTrue(isEnabled)
        // Locate the label by its stable accessibility id (not the display string),
        // then assert the rendered value so the count itself is still verified.
        let countLabel = app.staticTexts["fileCountLabel"]
        let countLabelExists = countLabel.waitForExistence(timeout: 5)
        XCTAssertTrue(countLabelExists)
        let countLabelValue = countLabel.label
        XCTAssertEqual(countLabelValue, "2 file(s) selected")
    }

    func testStubbedResultShowsResultUI() {
        let app = launchApp(preloadFiles: ["/tmp/a.mp3"], stubResult: "hello world")
        // The result editor and its actions appear only once there's a result —
        // the stub seam sets status = .completed without running WhisperKit.
        let editorExists = app.textViews["resultTextEditor"].waitForExistence(timeout: 10)
        XCTAssertTrue(editorExists)
        // Wait on each sibling rather than a bare `.exists`: they render in the same
        // body update as the editor, but the a11y tree may not have settled yet on a
        // loaded CI runner. waitForExistence returns immediately if already present.
        let copyExists = app.buttons["copyButton"].waitForExistence(timeout: 5)
        XCTAssertTrue(copyExists)
        let exportExists = app.buttons["exportButton"].waitForExistence(timeout: 5)
        XCTAssertTrue(exportExists)
        let statusExists = app.staticTexts["statusText"].waitForExistence(timeout: 5)
        XCTAssertTrue(statusExists)
        // Intentionally do NOT tap transcribeButton — it would load a model.
    }
}
