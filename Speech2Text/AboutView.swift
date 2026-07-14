import AppKit
import SwiftUI

/// The About panel, opened from the app menu ▸ About Speech2Text. Static content (it takes no
/// `TranscriptionManager`, unlike `ContentView`/`SettingsView`): the app identity, version, author,
/// license, source link, and the open-source acknowledgements for what actually ships in the binary.
/// Its scene wiring mirrors the Help window in `Speech2TextApp` — a single-instance `Window` plus a
/// dedicated menu command (`AboutMenuCommand`) that pulls `openWindow` from the environment.
struct AboutView: View {
    /// The About panel's title — one source shared by the `Window` scene and the app-menu item (both
    /// in `Speech2TextApp`), so they can't disagree (mirrors `HelpView.windowTitle`).
    static let windowTitle = "About Speech2Text"

    /// The About panel's window id — shared by the `Window` scene and the `openWindow` call in
    /// `Speech2TextApp` (mirrors `HelpView.windowID`).
    static let windowID = "about"

    /// The project's source URL — the app's one outbound link. `Link` opens it in the browser.
    private static let repositoryURL = URL(string: "https://github.com/popavel/speech2text")!

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text("Speech2Text")
                    .font(.title).bold()
                    .accessibilityIdentifier("aboutAppName")
                // Read live from the bundle (see `versionString`); omitted entirely when absent so
                // there's no misleading placeholder.
                if let version = Self.versionString {
                    Text(version)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("aboutVersion")
                }
                Text("Offline speech-to-text for audio and video.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Speech2Text transcribes audio and video to text entirely on your Mac, using "
                + "OpenAI's Whisper models running locally through WhisperKit.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 2) {
                Text("© 2026 Pavel Pozdnyakov")
                    .accessibilityIdentifier("aboutCopyright")
                Text("Released under the MIT License.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Link("github.com/popavel/speech2text", destination: Self.repositoryURL)
                .accessibilityIdentifier("aboutRepoLink")

            Divider()

            // Credits for the open-source components that ship inside the app binary (WhisperKit and
            // its vendored swift-transformers); OpenAI's Whisper is the underlying model. The full
            // license texts live in THIRD-PARTY-LICENSES.md at the repo root.
            VStack(alignment: .leading, spacing: 4) {
                Text("Acknowledgements")
                    .font(.subheadline).bold()
                Text("WhisperKit — MIT License (© 2024 argmax, inc.)")
                Text("swift-transformers — Apache-2.0 License (© 2022 Hugging Face SAS)")
                Text("OpenAI Whisper")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Without this the longest credit (swift-transformers) exceeds the panel's fixed 380pt
            // width and truncates with "…"; let it wrap to a second line instead, matching how the
            // description paragraph above handles its own width.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 380)
    }

    /// "Version X (Y)" read once from the bundle's Info.plist, which now maps
    /// `CFBundleShortVersionString`/`CFBundleVersion` from the `MARKETING_VERSION`/
    /// `CURRENT_PROJECT_VERSION` build settings — so this shows the real shipped version instead of a
    /// duplicated literal, and can't drift from `project.yml`. Computed a single time for the process
    /// (the bundle version is fixed for the process lifetime, so a `static let` avoids re-reading the
    /// Info.plist on every `body` render — mirrors how `HelpView` hoists its derived strings). `nil`
    /// when the bundle carries no version (only under a stripped test host), so the line is simply
    /// omitted there rather than showing a placeholder.
    private static let versionString: String? = {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else {
            return nil
        }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != short {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }()
}
