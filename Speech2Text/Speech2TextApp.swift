import SwiftUI

@main
struct Speech2TextApp: App {
    /// One manager shared by both scenes (main window + Settings) so storage cleanup in
    /// Settings resets the same live engine the main window uses. Created — and seeded for
    /// XCUITest — here rather than inside `ContentView`, which now receives it via
    /// `ContentView(manager:)`.
    @State private var manager: TranscriptionManager

    /// The app's one updater, shared by the menu command and the Settings toggle. Constructed in
    /// `init()` (not lazily in a view) because Sparkle's scheduled check has to start at launch,
    /// and because it needs `manager` for its busy check. The default `startingUpdater:` argument
    /// gates it off in test-hosted and `-uiTesting` processes, where it would otherwise construct
    /// Sparkle objects over the developer's real preferences — see
    /// `SparkleUpdaterModel.shouldStartUpdater`.
    @State private var updater: SparkleUpdaterModel

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
        // The busy check postpones an update's install-and-RELAUNCH (never the check itself — see
        // `UpdaterDelegate` for why guarding the check is the wrong fix) while work is in flight:
        // mid-transcription the run and the unexported transcript both live only in memory, and
        // mid-removal a relaunch would leave a half-deleted cache with the defaults cleanup
        // skipped, so "cleared" settings would survive. Both flags, matching every other busy gate
        // in the app. Capturing `manager` is safe: it holds no reference back to the updater, so
        // there is no cycle.
        _updater = State(
            initialValue: SparkleUpdaterModel(
                isBusy: { manager.isProcessing || manager.isRemovingData }
            )
        )
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
            // Replace the standard "About Speech2Text" app-menu item (whose stock panel shows
            // almost nothing — the shipped bundle carried no version string) with our own About
            // window. `openWindow` is reached the same way as Help, via a dedicated command `View`.
            CommandGroup(replacing: .appInfo) {
                AboutMenuCommand()
            }
            // "Check for Updates…" directly under About, where macOS apps conventionally put it.
            // Disabled whenever the updater can't check — including every gated (test) launch.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
            // Replace the default (help-book-less, and so broken) "Speech2Text Help" item with our
            // in-app help book — a NavigationSplitView window documenting the app's features, with
            // the full uninstall guide as its final topic. `openWindow` is available inside a
            // `Commands` body via @Environment.
            CommandGroup(replacing: .help) {
                HelpMenuCommand()
            }
        }

        // The About panel, opened from the app menu ▸ About Speech2Text. A single-instance `Window`
        // (like Help) so re-choosing the menu item brings the same panel forward rather than
        // spawning a second; `.contentSize` resizability gives it the tight, non-resizable feel of
        // the stock About panel. `.restorationBehavior(.disabled)` so it opens only on demand — an
        // auxiliary panel left open at quit shouldn't reappear on its own on the next launch (no
        // native About panel does).
        Window(AboutView.windowTitle, id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // The in-app help book, opened from Help ▸ Speech2Text Help. A standalone window so it can
        // stay open alongside the main window (its Uninstalling topic links into Settings).
        // `.restorationBehavior(.disabled)` (like About) so it opens only via the Help menu rather
        // than reappearing by itself when it was open at the previous quit.
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

/// The Help-menu item that opens the help book window. A dedicated `View` so it can pull
/// `openWindow` from the environment (a bare closure in `.commands` can't).
private struct HelpMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // No `.keyboardShortcut("?")`: macOS reserves ⌘? for the Help-menu search field it
        // auto-inserts, which wins the key equivalent — a custom binding here is a dead key.
        Button(HelpView.windowTitle) {
            openWindow(id: HelpView.windowID)
        }
    }
}

/// The app-menu item that opens the About panel. A dedicated `View` (like `HelpMenuCommand`) so it
/// can pull `openWindow` from the environment — a bare closure in `.commands` can't.
private struct AboutMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(AboutView.windowTitle) {
            openWindow(id: AboutView.windowID)
        }
    }
}
