import SwiftUI

@main
struct Speech2TextApp: App {
    /// One manager shared by both scenes (main window + Settings) so storage cleanup in
    /// Settings resets the same live engine the main window uses. Created — and seeded for
    /// XCUITest — here rather than inside `ContentView`, which now receives it via
    /// `ContentView(manager:)`.
    @State private var manager: TranscriptionManager

    init() {
        #if DEBUG
        // Under `-uiTesting`, persist settings to an isolated, volatile store instead of
        // `.standard` so UI tests are deterministic and can't clobber the developer's real
        // saved settings; a normal launch still uses `.standard`.
        let manager = TranscriptionManager(defaults: TranscriptionManager.uiTestSettingsStore())
        // Apply the XCUITest launch seam at the one place that now owns the manager
        // (previously ContentView.init). No-op unless launched with `-uiTesting`.
        manager.applyUITestSeamIfPresent()
        #else
        let manager = TranscriptionManager()
        #endif
        _manager = State(initialValue: manager)
    }

    var body: some Scene {
        // Single-instance `Window` (not `WindowGroup`): the app owns one shared
        // `manager`, so a second main window would mirror all state (files, progress,
        // result) between windows. `Window` is inherently single and drops the
        // File → New Window / New Tab commands, keeping one main window that shares
        // the engine with the Settings scene.
        Window("Speech2Text", id: "main") {
            ContentView(manager: manager)
        }
        .defaultSize(width: 700, height: 700)
        .commands {
            // Replace the default (help-book-less, and so broken) "Speech2Text Help" item with our
            // in-app help book — a NavigationSplitView window documenting the app's features, with
            // the full uninstall guide as its final topic. `openWindow` is available inside a
            // `Commands` body via @Environment.
            CommandGroup(replacing: .help) {
                HelpMenuCommand()
            }
        }

        // The in-app help book, opened from Help ▸ Speech2Text Help. A standalone window so it can
        // stay open alongside the main window (its Uninstalling topic links into Settings).
        Window(HelpView.windowTitle, id: "help") {
            HelpView()
        }
        .defaultSize(width: 720, height: 520)

        Settings {
            SettingsView(manager: manager)
        }
    }
}

/// The Help-menu item that opens the help book window. A dedicated `View` so it can pull
/// `openWindow` from the environment (a bare closure in `.commands` can't).
private struct HelpMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // No `.keyboardShortcut("?")`: macOS reserves ⌘? for the Help-menu search field it
        // auto-inserts, which wins the key equivalent — a custom binding here is a dead key.
        Button(HelpView.windowTitle) {
            openWindow(id: "help")
        }
    }
}
