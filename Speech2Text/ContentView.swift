import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// The app-owned shared `TranscriptionManager`, injected (not owned) by this view.
    /// `@Bindable` rather than `@State`: the manager's lifetime belongs to `Speech2TextApp`
    /// (which holds it in `@State` and hands the same instance to both this window and the
    /// Settings scene). `@Bindable` observes that instance and still exposes the `$manager.…`
    /// bindings the pickers/editor need, without re-wrapping it in this view's own state —
    /// so the view can never pin a stale manager if the app later supplies a new one.
    @Bindable var manager: TranscriptionManager
    @State private var isDragTargeted = false
    @State private var showFileImporter = false

    /// Inject the shared manager. Callers: `Speech2TextApp` (the real app + XCUITest path),
    /// the in-process ViewInspector suite (seeds state before inspecting the hierarchy), and
    /// `#Preview` (a throwaway instance).
    init(manager: TranscriptionManager) {
        _manager = Bindable(manager)
    }

    var body: some View {
        VStack(spacing: 20) {
            dropZone

            if !manager.droppedFileURLs.isEmpty {
                fileList
            }

            controlsRow

            transcribeButton

            if !manager.statusMessage.isEmpty {
                statusRow
            }

            if !manager.skippedFileNames.isEmpty {
                warningRow(skippedFilesMessage(manager.skippedFileNames))
            }

            if case .transcribing(let progress) = manager.status, progress > 0 {
                ProgressView(value: progress)
            }

            if !manager.transcriptionResult.isEmpty {
                resultSection
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 500)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            guard !manager.isProcessing else { return }
            if case .success(let urls) = result {
                manager.addFiles(urls)
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDragTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
                )

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Drop audio or video files here")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(Self.supportedFormatsCaption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Browse Files") {
                    showFileImporter = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("o")
                .accessibilityIdentifier("browseFilesButton")
            }
        }
        .frame(height: 150)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            guard !manager.isProcessing else { return false }
            loadDroppedFiles(from: providers)
            return true
        }
        .disabled(manager.isProcessing)
    }

    // MARK: - File List

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(manager.droppedFileURLs.count) file(s) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("fileCountLabel")
                Spacer()
                Button("Clear All") {
                    manager.clearFiles()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityIdentifier("clearAllButton")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(
                        Array(manager.droppedFileURLs.enumerated()),
                        id: \.offset
                    ) { index, url in
                        fileChip(url: url, index: index)
                    }
                }
            }
        }
        // Don't let "Clear All" / per-file removal mutate the queue while a run
        // is iterating it — that would leave an inconsistent completed state.
        .disabled(manager.isProcessing)
    }

    private func fileChip(url: URL, index: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: iconName(for: url))
                .font(.caption)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            Button {
                manager.removeFile(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("removeFileButton-\(index)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Language")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LanguagePicker(selection: $manager.selectedLanguage)
                    .frame(width: 160)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $manager.selectedModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                .accessibilityIdentifier("modelPicker")
            }

            Spacer()
        }
    }

    // MARK: - Transcribe Button

    private var transcribeButton: some View {
        HStack {
            Button {
                Task { await manager.startTranscription() }
            } label: {
                HStack(spacing: 8) {
                    if manager.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label(
                        manager.isProcessing ? "Transcribing..." : "Transcribe",
                        systemImage: "waveform"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!manager.canTranscribe)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("transcribeButton")
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 6) {
            Group {
                // A delete owns the display via the flag (see `statusMessage`), on top of
                // whatever `status` holds — so check it before switching on `status`.
                if manager.isDeletingModels {
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.blue)
                } else {
                    switch manager.status {
                    case .error:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .loadingModel, .transcribing:
                        Image(systemName: "circle.dotted")
                            .foregroundStyle(.blue)
                    default:
                        EmptyView()
                    }
                }
            }

            Text(manager.statusMessage)
                .font(.callout)
                .foregroundStyle(statusColor)
                .accessibilityIdentifier("statusText")

            Spacer()
        }
    }

    private func warningRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("skippedWarning")
            Spacer()
        }
    }

    private func skippedFilesMessage(_ names: [String]) -> String {
        let label = names.count == 1 ? "file" : "files"
        return "Unsupported \(label) skipped: \(names.joined(separator: ", "))"
    }

    // MARK: - Results

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcription")
                    .font(.headline)
                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        manager.transcriptionResult,
                        forType: .string
                    )
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("copyButton")

                Button {
                    exportText()
                } label: {
                    Label("Export .txt", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("exportButton")
            }

            TextEditor(text: $manager.transcriptionResult)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
                .frame(minHeight: 150, maxHeight: .infinity)
                .accessibilityIdentifier("resultTextEditor")
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        // Neutral while deleting, even if the underlying `status` is `.completed`/`.error`,
        // so "Deleting…" doesn't render in green/red.
        if manager.isDeletingModels { return .secondary }
        switch manager.status {
        case .error: return .red
        case .completed: return .green
        default: return .secondary
        }
    }

    // Derived from the manager's canonical sets so the UI never advertises or
    // icons a format the app doesn't actually accept. Static so the union/sort
    // runs once rather than on every render.
    private static let supportedFormatsCaption: String =
        TranscriptionManager.supportedAudioExtensions
            .union(TranscriptionManager.supportedVideoExtensions)
            .sorted()
            .joined(separator: ", ")

    private func iconName(for url: URL) -> String {
        TranscriptionManager.mediaKind(for: url) == .video ? "film" : "music.note"
    }

    private func loadDroppedFiles(from providers: [NSItemProvider]) {
        // Resolve every provider, then hand the whole drop to addFiles in a
        // single call. Adding one file at a time would let each call's
        // skipped-files bookkeeping overwrite the previous one's.
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await fileURL(from: provider) {
                    urls.append(url)
                }
            }
            // Resolving providers is async, so a transcription may have started
            // since the drop was accepted — re-check before mutating the queue.
            guard !manager.isProcessing else { return }
            if !urls.isEmpty {
                manager.addFiles(urls)
            }
        }
    }

    private func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    private func exportText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcription.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? manager.transcriptionResult.write(
                to: url, atomically: true, encoding: .utf8
            )
        }
    }
}

// MARK: - Language Picker

/// A searchable language picker. The full WhisperKit language set (~100 entries)
/// is too long for a plain menu, so this presents the current selection as a button
/// that opens a popover with a search field and a filtered, scrollable list.
///
/// `List` + `.searchable(text:)` was considered and rejected: `.searchable()` is only
/// reliable inside a `NavigationStack`, and in a bare `.popover` it has known rough edges
/// around search-field placement and content-driven sizing. Hence the hand-rolled
/// `TextField` + `ScrollView`. Type-to-filter is the navigation model; arrow-key row
/// cycling is intentionally not reimplemented, but Return selects the top match (`.onSubmit`).
private struct LanguagePicker: View {
    @Binding var selection: TranscriptionLanguage
    @State private var isPresented = false
    @State private var searchText = ""

    private var filtered: [TranscriptionLanguage] {
        TranscriptionLanguage.matching(searchText)
    }

    /// Commit a selection and dismiss the popover. Shared by the row tap and the
    /// Return-key (`.onSubmit`) path so the two can't drift.
    private func select(_ language: TranscriptionLanguage) {
        selection = language
        isPresented = false
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack {
                Text(selection.displayName)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("languagePicker")
        // Surface the current selection as the a11y value so XCUITest can read it
        // deterministically (same approach as fileCountLabel / statusText).
        .accessibilityValue(selection.displayName)
        .onChange(of: isPresented) { _, presented in
            // Clear the filter whenever the popover closes (selection or outside-click),
            // so reopening always starts from the full list.
            if !presented { searchText = "" }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                    .accessibilityIdentifier("languageSearchField")
                    // Return selects the top match for a real query, so keyboard-only
                    // users can type-then-Enter without reaching for the mouse. A blank
                    // query just dismisses — it must NOT select `filtered.first` (which
                    // is Auto-detect on the unfiltered list), or Return on an empty field
                    // would silently clobber the current selection.
                    .onSubmit {
                        if let target = TranscriptionLanguage.submitSelection(for: searchText) {
                            select(target)
                        } else {
                            isPresented = false
                        }
                    }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { language in
                            Button {
                                select(language)
                            } label: {
                                HStack {
                                    Text(language.displayName)
                                    Spacer()
                                    if language == selection {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            // displayName is unique per entry, so this is a stable,
                            // collision-free handle for XCUITest (cf. removeFileButton-N).
                            .accessibilityIdentifier("languageOption-\(language.displayName)")
                        }
                    }
                }
            }
            .frame(width: 240, height: 320)
        }
    }
}

// MARK: - Settings

/// The app's Settings scene (Cmd-,). A single "Storage" section that reports the size of
/// the downloaded WhisperKit model cache and lets the user delete it — the in-app half of
/// a graceful uninstall (macOS has no uninstaller hook, so an app can't clean up after
/// it's been trashed). It receives the app-level `TranscriptionManager` so deletion drops
/// the same live engine the main window uses, and the delete button can disable itself
/// while that window is transcribing.
struct SettingsView: View {
    let manager: TranscriptionManager

    @Environment(\.controlActiveState) private var controlActiveState

    @State private var cacheBytes: Int64?
    @State private var isWorking = false
    @State private var showDeleteConfirmation = false
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Downloaded models") {
                    Text(cacheSizeText)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("cacheSizeLabel")
                }

                Button("Delete Downloaded Models", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(manager.isProcessing || isWorking || (cacheBytes ?? 0) == 0)
                .accessibilityIdentifier("deleteModelsButton")

                if manager.isProcessing {
                    Text("Unavailable while a transcription is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 200)
        .task { refreshSize() }
        .onChange(of: controlActiveState) { _, state in
            // macOS builds the Settings window once and merely hides it on close, so
            // `.task` never re-fires on reopen — a model downloaded after the window was
            // first built would otherwise never show (and Delete would stay disabled).
            // `controlActiveState` is scoped to *this* window, so it flips to `.key` only
            // when the Settings window itself regains focus — unlike a global
            // didBecomeKey notification, which fired for every window app-wide.
            if state == .key { refreshSize() }
        }
        .confirmationDialog(
            "Delete all downloaded transcription models?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    isWorking = true
                    await manager.deleteAllModels()
                    isWorking = false
                    refreshSize()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var cacheSizeText: String {
        guard let cacheBytes else { return "Calculating…" }
        return cacheBytes > 0 ? Self.formatted(cacheBytes) : "None"
    }

    private var confirmationMessage: String {
        // The Delete button is disabled when the cache is empty, so the dialog only ever
        // presents with cacheBytes > 0; the `?? ""` is an unreachable safety fallback.
        let freedPrefix = cacheBytes.map { "This frees \(Self.formatted($0)). " } ?? ""
        return "\(freedPrefix)Models will re-download the next time you transcribe."
    }

    private static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Recompute the cache size off the main actor. Serialized: a new call cancels the
    /// previous task, and cancellation now propagates into the walk itself (the
    /// `cacheSize` loop bails on `Task.isCancelled`), so a superseded pre-delete walk is
    /// aborted rather than left to finish — and its partial result is dropped here too,
    /// so it can never resolve after a post-delete walk and stale-overwrite `cacheBytes`.
    /// `.utility` priority keeps the background size calc off the foreground's back.
    private func refreshSize() {
        refreshTask?.cancel()
        refreshTask = Task(priority: .utility) {
            let bytes = await manager.currentCacheSize()
            guard !Task.isCancelled else { return }
            cacheBytes = bytes
        }
    }
}

#Preview {
    ContentView(manager: TranscriptionManager())
}
