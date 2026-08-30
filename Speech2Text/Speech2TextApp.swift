import SwiftUI

@main
struct Speech2TextApp: App {
    /// One manager shared by both scenes, so storage cleanup in Settings resets the same live
    /// engine the main window uses.
    /// Why: docs/architecture.md#scenes-and-menu-commands
    @State private var manager: TranscriptionManager

    /// The app's one updater, shared by the menu command and the Settings toggle. Constructed in
    /// `init()` rather than lazily in a view, because Sparkle's scheduled check starts at launch.
    /// Why: docs/architecture.md#scenes-and-menu-commands
    @State private var updater: SparkleUpdaterModel

    init() {
        #if DEBUG
        // Under `-uiTesting`, persist to an isolated volatile store instead of `.standard`.
        // Why: docs/testing.md#the-seam-itself
        let manager = TranscriptionManager(defaults: TranscriptionManager.uiTestSettingsStore())
        // No-op unless launched with `-uiTesting`.
        manager.applyUITestSeamIfPresent()
        #else
        let manager = TranscriptionManager()
        #endif
        _manager = State(initialValue: manager)
        // Both flags, matching every other busy gate in the app. Capturing `manager` is safe — it
        // holds no reference back to the updater, so there is no cycle.
        // Why: docs/distribution.md#relaunch-not-check
        _updater = State(
            initialValue: SparkleUpdaterModel(
                isBusy: { manager.isProcessing || manager.isRemovingData }
            )
        )
    }

    var body: some Scene {
        // DO NOT change this to `WindowGroup` — the app owns one shared manager, so a second
        // main window would mirror all state between windows.
        // Why: docs/architecture.md#window-not-windowgroup
        Window("Speech2Text", id: "main") {
            ContentView(manager: manager)
        }
        .defaultSize(width: 700, height: 700)
        .commands {
            // Replace the stock About item, whose panel shows almost nothing.
            // Why: docs/architecture.md#menu-commands
            CommandGroup(replacing: .appInfo) {
                AboutMenuCommand()
            }
            // Directly under About, where macOS apps conventionally put it. Disabled whenever the
            // updater can't check, including every gated (test) launch.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
            // Replace the default, help-book-less (and so broken) Help item with the in-app book.
            // Why: docs/architecture.md#menu-commands
            CommandGroup(replacing: .help) {
                HelpMenuCommand()
            }
        }

        // Single-instance so re-choosing the menu item brings the same panel forward, and
        // restoration-disabled so it opens only on demand.
        // Why: docs/architecture.md#window-not-windowgroup
        Window(AboutView.windowTitle, id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // Standalone so it can stay open alongside the main window; restoration-disabled like
        // About.
        Window(HelpView.windowTitle, id: HelpView.windowID) {
            HelpView()
        }
        .defaultSize(width: 720, height: 520)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(manager: manager, updater: updater)
        }
    }
}

/// The Help-menu item that opens the help book. A dedicated `View` so it can pull `openWindow`
/// from the environment — a bare closure in `.commands` can't.
private struct HelpMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // NEVER add `.keyboardShortcut("?")` — macOS reserves ⌘? for the Help-menu search field.
        // Why: docs/architecture.md#menu-commands
        Button(HelpView.windowTitle) {
            openWindow(id: HelpView.windowID)
        }
    }
}

/// The app-menu item that opens the About panel. A dedicated `View`, like `HelpMenuCommand`.
private struct AboutMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(AboutView.windowTitle) {
            openWindow(id: AboutView.windowID)
        }
    }
}
