import SwiftUI
// `DecodingTask` (the Transcribing topic's task list) is a WhisperKit type; `WhisperModel`,
// the supported-format sets, and `bundleIdentifier` are app types and need no import. Matches
// ContentView's `@preconcurrency` import so the Swift 6 strict-concurrency posture is consistent.
@preconcurrency import WhisperKit

// MARK: - Help Book

/// A topic in the in-app help book. `CaseIterable` order is the sidebar order; `Uninstalling` is
/// last because it's the end-of-life task (it absorbed the former standalone uninstall window).
enum HelpTopic: String, CaseIterable, Identifiable, Hashable {
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

/// The in-app help book, opened from Help ▸ Speech2Text Help (⌘?). A `NavigationSplitView` whose
/// sidebar lists the `HelpTopic`s and whose detail renders the selected one. Replaces the former
/// standalone "Uninstalling Speech2Text…" window — uninstalling is now this book's final topic.
///
/// Every factual detail (supported formats, model names/sizes, task labels, the uninstall leftover
/// paths) is derived from `TranscriptionManager`'s canonical `static` declarations so the
/// documentation can't drift from the code it describes.
struct HelpView: View {
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
            // `selection` is only nil transiently (e.g. a sidebar deselect); fall back to Overview
            // so the detail pane always shows something.
            HelpDetailView(topic: selection ?? .overview)
        }
        .navigationTitle("Speech2Text Help")
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
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("helpDetail-\(topic.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
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
            Text("Supported audio: \(Self.audioExtensions)")
                .fixedSize(horizontal: false, vertical: true)
            Text("Supported video: \(Self.videoExtensions)")
                .fixedSize(horizontal: false, vertical: true)
            paragraph("For video files the audio track is extracted automatically before "
                + "transcription. You can queue several files at once; duplicates are ignored, and "
                + "unsupported files are skipped with a warning instead of stopping the batch.")
            paragraph("Use the × on a file to remove it, or Clear All to empty the queue.")
        }
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 10) {
            paragraph("Language defaults to Auto-detect, which lets the model infer the spoken "
                + "language. To force a specific one, click the language button and use the search "
                + "field — type part of a name and press Return to pick the top match.")
            paragraph("The full Whisper language set (around 100 languages) is available.")
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 10) {
            paragraph("The model sets the balance of speed, accuracy, and download size. Larger "
                + "models are more accurate but slower and use more disk space. Base is a good "
                + "default.")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(WhisperModel.allCases) { model in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        // The display name (with its size) comes straight from WhisperModel so this
                        // list can't advertise a model or size the app doesn't actually offer.
                        Text(model.displayName)
                    }
                }
            }
            paragraph("A model downloads the first time you use it, which can take a while; after "
                + "that it's cached and reused. Manage downloaded models in Settings ▸ Storage.")
        }
    }

    private var transcribing: some View {
        VStack(alignment: .leading, spacing: 10) {
            paragraph("Task controls what the model produces:")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(DecodingTask.allCases, id: \.self) { task in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(task.displayName)
                    }
                }
            }
            paragraph("Under Advanced, Temperature trades determinism for variety — 0 is most "
                + "accurate; higher values add randomness.")
            paragraph("Click Transcribe (⌘⏎) to start. The first run loads the model, and progress "
                + "is shown as a percentage. When several files are queued, each file's text is "
                + "preceded by a “--- filename ---” header.")
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
            paragraph("Open Settings with ⌘, to manage what the app keeps on disk:")
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
            paragraph("Models are stored under ~/Library/Application Support/"
                + "\(TranscriptionManager.bundleIdentifier)/models.")
        }
    }

    private var uninstalling: some View {
        VStack(alignment: .leading, spacing: 16) {
            paragraph("Speech2Text isn't sandboxed, so dragging it to the Trash leaves some data "
                + "behind. Here's how to remove all of it.")

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Remove the app's data").font(.headline)
                paragraph("Open Settings below, then click Remove All App Data and confirm. This "
                    + "deletes the downloaded models and clears your saved settings. It removes:")
                pathRow(Self.appDataPath)
                SettingsLink {
                    Text("Open Settings…")
                }
                .accessibilityIdentifier("openSettingsLink")
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("2. Quit and remove the app").font(.headline)
                paragraph("Quit Speech2Text, then drag it from Applications to the Trash.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("3. (Optional) Remove leftover system files").font(.headline)
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

    /// A bold term above a one-line description — used for the Settings control glossary.
    private func labeledItem(_ term: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term).font(.subheadline).bold()
            paragraph(description)
        }
    }

    /// A copy-selectable, monospaced file path (matches the former UninstallHelpView styling).
    private func pathRow(_ path: String) -> some View {
        Text(path)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
    }

    // MARK: Derived content

    // Sorted + joined once. Kept identical to the manager's canonical sets so the render tests can
    // recompute the exact same strings and catch any documentation drift.
    private static let audioExtensions =
        TranscriptionManager.supportedAudioExtensions.sorted().joined(separator: ", ")
    private static let videoExtensions =
        TranscriptionManager.supportedVideoExtensions.sorted().joined(separator: ", ")

    /// What "Remove All App Data" wipes — the app-owned Application Support root. Its bundle-id
    /// segment comes from the shared `TranscriptionManager.bundleIdentifier`, so a rename can't
    /// leave the guide pointing at a stale folder.
    private static let appDataPath =
        "~/Library/Application Support/\(TranscriptionManager.bundleIdentifier)"

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

#Preview("Help — Uninstalling") {
    HelpDetailView(topic: .uninstalling)
}
