import SwiftUI

@main
struct Speech2TextApp: App {
    /// One manager shared by both scenes (main window + Settings) so storage cleanup in
    /// Settings resets the same live engine the main window uses. Created — and seeded for
    /// XCUITest — here rather than inside `ContentView`, which now receives it via
    /// `ContentView(manager:)`.
    @State private var manager: TranscriptionManager

    init() {
        let manager = TranscriptionManager()
        #if DEBUG
        // Apply the XCUITest launch seam at the one place that now owns the manager
        // (previously ContentView.init). No-op unless launched with `-uiTesting`.
        manager.applyUITestSeamIfPresent()
        #endif
        _manager = State(initialValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
        }
        .defaultSize(width: 700, height: 700)

        Settings {
            SettingsView(manager: manager)
        }
    }
}
