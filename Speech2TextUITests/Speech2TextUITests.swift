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

    override func tearDown() {
        // Terminate the app after every test — pass or fail. The help book is a second, restorable
        // `Window`; if a test opens it and then fails before closing it (continueAfterFailure = false
        // aborts at the first failed assertion), the window would otherwise be left open and could be
        // restored into the next test, which assumes a single main window. Terminating here kills any
        // such window regardless of the failure path. (`terminate()` is a no-op if nothing is running,
        // and abnormal termination doesn't persist window state — so nothing is restored on relaunch.)
        // Suppressing restoration via `-NSQuitAlwaysKeepsWindows NO` / `-ApplePersistenceIgnoreState`
        // launch args was tried instead, but those prevent this SwiftUI app's main window from
        // appearing at all.
        XCUIApplication().terminate()
        super.tearDown()
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
        // (Window-restoration hygiene for the help book's second window is handled by
        // terminating the app in tearDown — see there.)
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

    // MARK: - Help book

    /// Open Help ▸ Speech2Text Help from the menu bar and return the book window. Menu-bar and
    /// second-window driving is new for this suite (every other test stays in the main window),
    /// so it's centralized here.
    private func openHelpBook(_ app: XCUIApplication) -> XCUIElement {
        let helpMenu = app.menuBars.menuBarItems["Help"]
        // Wait for the menu bar to populate before clicking — `.click()` snapshots the a11y tree
        // at call time and doesn't wait for existence, so on a cold/loaded runner the item may not
        // be there the instant `app.launch()` returns. Matches the suite's assertExists-first pattern.
        assertExists(helpMenu, timeout: 10)
        helpMenu.click()
        // Scope the item lookup to the open Help menu. An unscoped `app.menuBars.menuItems[...]`
        // matches the same item twice — the macOS menu bar is reachable via two accessibility-tree
        // paths — and its `.firstMatch` can resolve to an off-screen phantom with an INFINITY frame
        // that XCUITest refuses to click. Scoping under the (uniquely resolved) Help menu bar item
        // yields the one real, hittable "Speech2Text Help" item.
        let helpItem = helpMenu.menuItems["Speech2Text Help"]
        // Wait for the menu to populate before clicking — `.click()` doesn't wait for existence, and
        // the menu items may not be in the a11y tree the instant the menu opens on a cold runner.
        assertExists(helpItem)
        helpItem.click()
        let window = app.windows["Speech2Text Help"]
        assertExists(window, timeout: 10)
        return window
    }

    /// A help element addressed by accessibility identifier, searched within `container` (the help
    /// window) so the lookup can't stray to a same-id element elsewhere in the app tree. Matched
    /// regardless of the element type it surfaces as: a macOS `List` row or a `ScrollView` can
    /// appear as a cell, static text, or generic element — not necessarily a button — so a typed
    /// query (`container.buttons[...]`) would silently miss it.
    private func helpElement(_ container: XCUIElement, _ identifier: String) -> XCUIElement {
        container.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testHelpBookOpensFromMenuAndNavigatesTopics() {
        let app = launchApp()
        let helpWindow = openHelpBook(app)

        // openSettingsLink lives only on the Uninstalling topic, so its presence/absence is a
        // clean, type-agnostic signal for which detail pane is showing.
        let settingsLink = helpElement(helpWindow, "openSettingsLink")

        // The book opens on Overview (the default selection). Assert the Overview *detail* pane is
        // showing — the sidebar row `helpTopic-overview` is present for every selection, so on its
        // own it can't prove the default; `helpDetail-overview` (the detail pane's id) can. Also
        // assert the uninstalling-only Settings link is absent.
        assertExists(helpElement(helpWindow, "helpTopic-overview"), timeout: 10)
        assertExists(helpElement(helpWindow, "helpDetail-overview"))
        XCTAssertFalse(
            settingsLink.exists,
            "Open Settings link should only appear on the Uninstalling topic"
        )

        // Navigate to Uninstalling → its Settings link appears. Because that link is unique to
        // the topic, its appearance proves the sidebar selection swapped the detail pane.
        let uninstallingRow = helpElement(helpWindow, "helpTopic-uninstalling")
        assertExists(uninstallingRow)
        uninstallingRow.click()
        assertExists(settingsLink)

        // Navigate on to Models → the Uninstalling-only link disappears, proving the detail pane
        // updates in both directions.
        let modelsRow = helpElement(helpWindow, "helpTopic-models")
        assertExists(modelsRow)
        modelsRow.click()
        XCTAssertTrue(
            settingsLink.waitForNonExistence(timeout: 5),
            "Open Settings link should disappear when leaving the Uninstalling topic"
        )

        // Close the second window so state restoration can't carry it into a later test.
        helpWindow.buttons[XCUIIdentifierCloseWindow].click()
    }
}
