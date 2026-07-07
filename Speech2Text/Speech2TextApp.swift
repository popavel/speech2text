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
            // Replace the default (help-book-less, and so broken) "Speech2Text Help" item with a
            // guide to fully uninstalling the app — the app isn't sandboxed, so macOS reaps nothing
            // when it's trashed. `openWindow` is available inside a `Commands` body via @Environment.
            CommandGroup(replacing: .help) {
                UninstallHelpCommand()
            }
        }

        // Standalone window opened from Help ▸ Uninstalling Speech2Text…. Independent of the main
        // window so it can stay open while the user follows its "Open Settings…" link to the wipe.
        Window("Uninstalling Speech2Text", id: "uninstall") {
            UninstallHelpView()
        }
        .defaultSize(width: 460, height: 520)

        Settings {
            SettingsView(manager: manager)
        }
    }
}

/// The Help-menu item that opens the uninstall guide window. A dedicated `View` so it can pull
/// `openWindow` from the environment (a bare closure in `.commands` can't).
private struct UninstallHelpCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Uninstalling Speech2Text…") {
            openWindow(id: "uninstall")
        }
    }
}
