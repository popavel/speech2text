import SwiftUI
// `DecodingTask` (the Transcribing topic's task list) is a WhisperKit type; `WhisperModel`,
// the supported-format sets, and `bundleIdentifier` are app types and need no import. Matches
// ContentView's `@preconcurrency` import so the Swift 6 strict-concurrency posture is consistent.
@preconcurrency import WhisperKit

// MARK: - Help Book

/// A topic in the in-app help book. `CaseIterable` order is the sidebar order; `Uninstalling` is
/// last because it's the end-of-life task (it absorbed the former standalone uninstall window).
enum HelpTopic: String, CaseIterable, Identifiable {
    case overview
    case addingFiles
    case languages
    case models
    case transcribing
    case results
    case storage
    case uninstalling

    var id: String { rawValue }

    /// Sidebar row label (and the detail pane's heading).
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .addingFiles: return "Adding files"
        case .languages: return "Languages"
        case .models: return "Models"
        case .transcribing: return "Transcribing"
        case .results: return "Results"
        case .storage: return "Storage & data"
        case .uninstalling: return "Uninstalling"
        }
    }

    /// SF Symbol for the sidebar row.
    var systemImage: String {
        switch self {
        case .overview: return "info.circle"
        case .addingFiles: return "doc.badge.plus"
        case .languages: return "globe"
        case .models: return "cpu"
        case .transcribing: return "waveform"
        case .results: return "doc.text"
        case .storage: return "internaldrive"
        case .uninstalling: return "trash"
        }
    }
}

/// The in-app help book, opened from Help ▸ Speech2Text Help. A `NavigationSplitView` whose
/// sidebar lists the `HelpTopic`s and whose detail renders the selected one. Replaces the former
/// standalone "Uninstalling Speech2Text…" window — uninstalling is now this book's final topic.
///
/// Facts that can drift from the code are derived from `TranscriptionManager`'s canonical `static`
/// declarations and are covered by `HelpViewTests`: supported formats, model display names and the
/// default model, the default language name, task labels, the storage/uninstall paths, the
/// batch-run header, and the language count. The rest of the copy is illustrative prose that is NOT
/// derived, so a rebind or a control
/// rename has to be mirrored here by hand. That non-derived surface is every keyboard shortcut
/// (⌘O/⌘⏎/⌘,) and every ContentView control label named in the text — e.g. the Settings labels
/// ("Downloaded models", "Delete Downloaded Models", "Remove All App Data", "Restore Default
/// Settings"), the main-window controls ("Browse Files", "Clear All", "Task", "Advanced",
/// "Temperature", "Transcribe", "Copy", "Export .txt") and the "Storage" section.
/// Renaming any of these in `ContentView` builds green and passes tests while leaving the help book
/// misdescribing the UI.
struct HelpView: View {
    /// The help book's title — one source shared by the `Window` scene, the Help-menu item (both in
    /// `Speech2TextApp`), and this view's `navigationTitle`, so they can't disagree. The XCUITest
    /// pins the visible string independently (a separate target that can't reference this constant).
    static let windowTitle = "Speech2Text Help"

    /// The help book's window id — shared by the `Window` scene and the `openWindow` call in
    /// `Speech2TextApp`, so they can't disagree (mirrors `windowTitle`).
    static let windowID = "help"

    /// The topic the detail pane shows for a given sidebar selection: the selected topic, or
    /// Overview when `selection` is nil (a transient sidebar deselect). Pulled out as a pure
    /// function so the nil-fallback is unit-testable directly — static ViewInspection always reads
    /// the `.overview` `@State` seed and so can never exercise this branch (would need ViewHosting).
    static func detailTopic(_ selection: HelpTopic?) -> HelpTopic { selection ?? .overview }

    @State private var selection: HelpTopic? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(HelpTopic.allCases) { topic in
                    // `.tag(topic)` makes the selection value a `HelpTopic`, so `selection` can be a
                    // `HelpTopic?` (rather than the element's `id`) and drives the detail directly.
                    // The identifier gives XCUITest a stable hook per row (titles like "Storage &
                    // data" are brittle to match by text) — mirrors `helpDetail-<rawValue>`.
                    Label(topic.title, systemImage: topic.systemImage)
                        .tag(topic)
                        .accessibilityIdentifier("helpTopic-\(topic.rawValue)")
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            // `selection` is only nil transiently (e.g. a sidebar deselect); `detailTopic` falls
            // back to Overview so the detail pane always shows something.
            HelpDetailView(topic: Self.detailTopic(selection))
        }
        .navigationTitle(Self.windowTitle)
    }
}

/// The detail pane for a single `HelpTopic`. Owns the sole `ScrollView` + padding so each topic's
/// content is a plain, independently-inspectable block (no nested scrolling) — which is also why the
/// render tests can build one per topic and assert on it directly.
struct HelpDetailView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(topic.title)
                    .font(.title2).bold()
                switch topic {
                case .overview: overview
                case .addingFiles: addingFiles
                case .languages: languages
                case .models: models
                case .transcribing: transcribing
                case .results: results
                case .storage: storage
                case .uninstalling: uninstalling
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Give the ScrollView a per-topic identity so switching topics rebuilds a fresh scroll
        // container: without this, `HelpDetailView` keeps stable identity in the detail slot and the
        // reused ScrollView can retain a prior topic's scroll offset (e.g. show a short topic already
        // scrolled past its content). A distinct `.id` resets the offset to the top on each switch.
        .id(topic)
        .accessibilityIdentifier("helpDetail-\(topic.rawValue)")
    }

    // MARK: Topics

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            paragraph("Speech2Text transcribes audio and video to text entirely on your Mac. It "
                + "uses OpenAI Whisper models running locally through WhisperKit, so your files "
                + "never leave your computer and no internet connection is needed once a model has "
                + "been downloaded.")
            paragraph("Add one or more files, optionally pick a language and model, then click "
                + "Transcribe. The result appears in an editable box you can copy or export.")
            paragraph("Downloaded models and saved settings are managed in Settings (⌘,).")
        }
    }

    private var addingFiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            paragraph("Add files two ways: drag them onto the window, or click Browse Files (⌘O) "
                + "and choose one or more.")
            paragraph("Supported audio: \(Self.audioExtensions)")
            paragraph("Supported video: \(Self.videoExtensions)")
            paragraph("For video files the audio track is extracted automatically before "
                + "transcription. You can queue several files at once; duplicates are ignored, and "
                + "unsupported files are skipped with a warning instead of stopping the batch.")
            paragraph("Use the × on a file to remove it, or Clear All to empty the queue.")
        }
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Default-language name derived from canonical source (mirrors the Models topic's
            // `Defaults.model.shortName`) so a rename of `TranscriptionLanguage.auto` can't leave
            // this line describing a control label the app no longer shows.
            paragraph("Language defaults to \(TranscriptionManager.Defaults.language.displayName), "
                + "which lets the model infer the spoken language. To force a specific one, click "
                + "the language button and use the search field — type part of a name and press "
                + "Return to pick the top match.")
            paragraph("The full Whisper language set (around "
                + "\(TranscriptionLanguage.spokenLanguageCount) languages) is available.")
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 10) {
            paragraph("The model sets the balance of speed, accuracy, and download size. Larger "
                + "models are more accurate but slower and use more disk space. "
                + "\(TranscriptionManager.Defaults.model.shortName) is a good default.")
            // Display names (with their sizes) come straight from WhisperModel so this list can't
            // advertise a model or size the app doesn't actually offer.
            bulletList(Self.modelNames)
            paragraph("A model downloads the first time you use it, which can take a while; after "
                + "that it's cached and reused. Manage downloaded models in Settings ▸ Storage.")
        }
    }

    private var transcribing: some View {
        VStack(alignment: .leading, spacing: 10) {
            paragraph("Task controls what the model produces:")
            bulletList(Self.taskNames)
            paragraph("Under Advanced, Temperature trades determinism for variety — 0 is most "
                + "accurate; higher values add randomness.")
            paragraph("Click Transcribe (⌘⏎) to start. The first run loads the model, which can "
                + "take a moment. When several files are queued they’re processed in turn and the "
                + "progress bar advances as each one finishes; each file’s text is preceded by a "
                + "“\(TranscriptionManager.batchHeader(forFileNamed: "filename"))” header.")
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            paragraph("The transcription appears in an editable text box, so you can correct any "
                + "mistakes before saving.")
            paragraph("Copy places the full text on the clipboard. Export .txt saves it as a plain "
                + "text file.")
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 10) {
            paragraph("Open Settings with ⌘, to manage downloaded models and your saved settings:")
            VStack(alignment: .leading, spacing: 8) {
                labeledItem("Downloaded models",
                    "Shows how much space cached models use.")
                labeledItem("Delete Downloaded Models",
                    "Frees that space; models re-download the next time you transcribe.")
                labeledItem("Remove All App Data",
                    "Deletes models and clears saved settings to prepare for uninstalling.")
                labeledItem("Restore Default Settings",
                    "Resets task, language, model, and temperature.")
            }
            paragraph("Models are stored under:")
            pathRow(Self.modelsPath, id: "modelsPathRow")
        }
    }

    private var uninstalling: some View {
        VStack(alignment: .leading, spacing: 16) {
            paragraph("Speech2Text isn't sandboxed, so dragging it to the Trash leaves some data "
                + "behind. Here's how to remove all of it.")

            step(1, "Remove the app's data") {
                paragraph("Open Settings below, then click Remove All App Data and confirm. This "
                    + "deletes the downloaded models and clears your saved settings. It removes:")
                pathRow(Self.appDataPath, id: "appDataPathRow")
                SettingsLink {
                    Text("Open Settings…")
                }
                .accessibilityIdentifier("openSettingsLink")
                .padding(.top, 2)
            }

            step(2, "Quit and remove the app") {
                paragraph("Quit Speech2Text, then drag it from Applications to the Trash.")
            }

            step(3, "(Optional) Remove leftover system files") {
                paragraph("After quitting, macOS may keep these small files. Delete them for a "
                    + "completely clean removal:")
                ForEach(Self.systemPaths, id: \.self) { pathRow($0) }
            }
        }
    }

    // MARK: Helpers

    /// A body paragraph that wraps instead of truncating.
    private func paragraph(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A "• item" bulleted list of plain strings. Shared by the Models and Transcribing topics,
    /// whose items are the canonical `WhisperModel` / `DecodingTask` display names.
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(item)
                }
            }
        }
    }

    /// A numbered step in the Uninstalling walkthrough: a bold "N. Title" headline above its
    /// content. Extracted so the three (and any future) steps share one shape.
    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number). \(title)").font(.headline)
            content()
        }
    }

    /// A bold term above a one-line description — used for the Settings control glossary.
    private func labeledItem(_ term: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term).font(.subheadline).bold()
            paragraph(description)
        }
    }

    /// A copy-selectable, monospaced file path (matches the former UninstallHelpView styling).
    /// Pass `id` to attach a stable accessibility hook so a specific row can be asserted by exact
    /// identifier (Storage's models path, Uninstalling's app-data path); rows without one (the four
    /// systemPaths crumbs) render unidentified. An empty identifier is equivalent to none.
    private func pathRow(_ path: String, id: String? = nil) -> some View {
        Text(path)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(id ?? "")
    }

    // MARK: Derived content

    // Sorted + joined once. Kept identical to the manager's canonical sets so the render tests can
    // recompute the exact same strings and catch any documentation drift.
    private static let audioExtensions =
        TranscriptionManager.supportedAudioExtensions.sorted().joined(separator: ", ")
    private static let videoExtensions =
        TranscriptionManager.supportedVideoExtensions.sorted().joined(separator: ", ")

    // Canonical model/task labels, computed once (mirrors the extension strings above rather than
    // rebuilding the array on every render of the Models / Transcribing panes). The render tests
    // recompute these from the same `allCases.map(\.displayName)` so documentation drift still trips.
    private static let modelNames = WhisperModel.allCases.map(\.displayName)
    private static let taskNames = DecodingTask.allCases.map(\.displayName)

    /// Tilde-abbreviated display form of an app-owned URL (e.g. `~/Library/Application Support/…`).
    private static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// What "Remove All App Data" wipes — shown as the tilde-abbreviated path of the exact URL the
    /// wipe removes (`TranscriptionManager.appSupportDirectory`), so the guide can't point at a
    /// folder the app no longer uses.
    private static let appDataPath = abbreviated(TranscriptionManager.appSupportDirectory)

    /// Where downloaded models live — the tilde-abbreviated path of `modelCacheDirectory`, the same
    /// URL WhisperKit downloads into, so the Storage topic stays in sync with the real cache.
    private static let modelsPath = abbreviated(TranscriptionManager.modelCacheDirectory)

    /// OS-managed crumbs the in-app wipe can't reach (the prefs `.plist` survives because SwiftUI
    /// and cfprefsd keep re-materializing that domain), best removed manually after quitting.
    private static let systemPaths: [String] = {
        let id = TranscriptionManager.bundleIdentifier
        return [
            "~/Library/Preferences/\(id).plist",
            "~/Library/Saved Application State/\(id).savedState",
            "~/Library/HTTPStorages/\(id)",
            "~/Library/Caches/\(id)",
        ]
    }()
}

#Preview("Help") {
    HelpView()
}
