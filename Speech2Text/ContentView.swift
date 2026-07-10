import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import WhisperKit

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

            advancedSection

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
            labeledControl("Language") {
                LanguagePicker(selection: $manager.selectedLanguage)
                    .frame(width: 160)
            }

            labeledControl("Model") {
                Picker("", selection: $manager.selectedModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                .accessibilityIdentifier("modelPicker")
            }

            labeledControl("Task") {
                Picker("", selection: $manager.selectedTask) {
                    ForEach(DecodingTask.allCases, id: \.self) { task in
                        Text(task.displayName).tag(task)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityIdentifier("taskPicker")
            }

            Spacer()
        }
    }

    /// A caption stacked above a control — the shared layout for the Language/Model/Task pickers
    /// in `controlsRow`, extracted so the caption styling lives in one place.
    @ViewBuilder
    private func labeledControl<Content: View>(
        _ caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f", manager.temperature))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $manager.temperature, in: 0...1, step: 0.1)
                    .accessibilityIdentifier("temperatureSlider")
                Text("0 = most accurate; higher adds randomness.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .accessibilityIdentifier("advancedDisclosure")
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
                if manager.isRemovingData {
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
        if manager.isRemovingData { return .secondary }
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
    @State private var showDeleteConfirmation = false
    @State private var showWipeConfirmation = false
    @State private var showRestoreConfirmation = false
    /// Set when a destructive removal ran but left its target on disk (a genuine failure, not a
    /// no-op); drives the error alert so a failed wipe can't masquerade as success.
    @State private var showRemovalError = false
    @State private var refreshTask: Task<Void, Never>?
    /// Whether a size walk is currently in flight. Coalesces the `.task` +
    /// `.onChange(controlActiveState)` double-fire on first open (and rapid refocus)
    /// into a single walk. Cleared by the walk itself and by the delete path.
    @State private var isMeasuring = false
    /// Bumped on each measure so a superseded walk can tell it is no longer the
    /// current one and must not touch the shared `isMeasuring`/`cacheBytes` state.
    @State private var measureGeneration = 0

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
                .disabled(manager.isProcessing || manager.isRemovingData || !hasCache)
                .accessibilityIdentifier("deleteModelsButton")

                Button("Remove All App Data", role: .destructive) {
                    showWipeConfirmation = true
                }
                // No `hasCache` gate: settings persist even with an empty model cache, so the
                // complete-uninstall wipe stays available regardless of what's downloaded.
                .disabled(manager.isProcessing || manager.isRemovingData)
                .accessibilityIdentifier("removeAllDataButton")

                if manager.isProcessing {
                    Text("Unavailable while a transcription is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Defaults") {
                Button("Restore Default Settings") {
                    showRestoreConfirmation = true
                }
                .disabled(manager.isProcessing)
                .accessibilityIdentifier("restoreDefaultsButton")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
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
                performRemoval(of: TranscriptionManager.modelCacheDirectory) {
                    await manager.deleteAllModels()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .confirmationDialog(
            "Remove all Speech2Text data?",
            isPresented: $showWipeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All Data", role: .destructive) {
                performRemoval(of: TranscriptionManager.appSupportDirectory) {
                    await manager.removeAllAppData()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all downloaded models and your saved settings. This prepares the app for "
                + "removal — afterwards, quit and drag Speech2Text to the Trash.")
        }
        .confirmationDialog(
            "Restore default settings?",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore") { manager.restoreDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Task, language, model, and temperature will return to their defaults.")
        }
        // Shared by both destructive buttons, so the copy stays operation-neutral (no "all data" /
        // uninstall wording that would misdirect a models-only delete failure).
        .alert("Couldn’t remove files", isPresented: $showRemovalError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Some files couldn’t be removed — check permissions and try again, or remove them "
                + "manually.")
        }
    }

    /// Whether a measured, non-empty cache exists — the plain-Int predicate the delete
    /// button gates on, kept separate from the display string so enablement doesn't hinge
    /// on formatting.
    private var hasCache: Bool { (cacheBytes ?? 0) > 0 }

    /// The formatted cache size when `hasCache`, else `nil` (still calculating, or empty).
    /// Single source of truth for the size *string*, shared by the size label and the
    /// confirmation copy so they don't each re-derive it from the optional `cacheBytes`.
    private var formattedCacheSize: String? {
        guard hasCache, let cacheBytes else { return nil }
        return Self.formatted(cacheBytes)
    }

    private var cacheSizeText: String {
        if let formattedCacheSize { return formattedCacheSize }
        return cacheBytes == nil ? "Calculating…" : "None"
    }

    private var confirmationMessage: String {
        // The Delete button is disabled unless a positive, measured cache exists, so the
        // dialog only ever presents with a non-nil `formattedCacheSize`; the `?? ""` is an
        // unreachable safety fallback.
        let freedPrefix = formattedCacheSize.map { "This frees \($0). " } ?? ""
        return "\(freedPrefix)Models will re-download the next time you transcribe."
    }

    private static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Run a destructive removal and reconcile the displayed cache size — shared by the
    /// Delete-Downloaded-Models and Remove-All-App-Data buttons. `directory` is the tree the removal
    /// targets, used afterwards only to tell a genuine failure from a harmless no-op.
    ///
    /// Cancels any in-flight display walk before the removal, so a GB-scale enumerator doesn't race
    /// `removeItem` for the same tree; a walk can't *start* mid-removal because `refreshSize()` bails
    /// while `isRemovingData` is set, and the manager sets that busy-state synchronously before the
    /// removal's first suspension. **`removal` must be `@MainActor`** for that to hold: a nonisolated
    /// `() async -> Bool` would hop off the main actor at `await removal()` (SE-0338) *before*
    /// `deleteAllModels`/`removeAllAppData` runs, leaving `deletion` nil across a suspension that a
    /// refocus (`controlActiveState` → `.key` on dialog dismissal) could slip a fresh walk into. With
    /// `@MainActor` the call is same-actor and runs straight into `wipeDirectory`, which sets
    /// `deletion` before it suspends. The cancelled walk's own `isMeasuring = false` may not have
    /// landed yet, so clear it here too — otherwise the no-op branch's `refreshSize()` below would be
    /// blocked by the coalescing guard. On success the tree is gone (size 0), set directly rather than
    /// re-walking an emptied tree; otherwise re-walk so residual bytes aren't misreported as "None",
    /// and surface an error only for a genuine failure — see the busy-flag gate below.
    private func performRemoval(
        of directory: URL,
        _ removal: @escaping @MainActor () async -> Bool
    ) {
        Task {
            refreshTask?.cancel()
            isMeasuring = false
            let removed = await removal()
            if removed {
                cacheBytes = 0
            } else {
                refreshSize()
                // A `false` result can mean two very different things: a genuine failure (a real
                // attempt that left the target on disk), or the manager *refusing* the removal
                // because a transcription or another removal is in flight — which leaves everything
                // intact by design and is NOT an error. Only a real attempt clears the busy flags
                // by the time it returns, so if either is still set the call was refused; suppress
                // the alert then. This runs synchronously right after `removal()` on the main actor,
                // so the flags reflect the exact post-call state with no interleaving.
                if !manager.isProcessing, !manager.isRemovingData,
                   FileManager.default.fileExists(atPath: directory.path) {
                    showRemovalError = true
                }
            }
        }
    }

    /// Recompute the cache size off the main actor.
    ///
    /// Coalesced via `isMeasuring`: a call while a walk is already running is a no-op, so the
    /// `.task` + `.onChange(controlActiveState)` double-fire on first open (and rapid refocus)
    /// collapses to a single walk. A genuine refocus after this one finishes still re-measures,
    /// because the flag is clear by then. The delete path clears `isMeasuring` where it cancels
    /// the walk, so its post-delete re-measure isn't blocked.
    ///
    /// Bails while a delete is in flight: a walk begun against a tree being removed could
    /// read a partial size and land after the delete publishes `0`. `deleteAllModels` sets
    /// `isRemovingData` synchronously before its first suspension and clears it only after,
    /// so this guard covers the whole delete — no walk can start mid-delete.
    ///
    /// Deliberately does NOT blank `cacheBytes`: the first measure already starts from `nil`
    /// (showing "Calculating…"), while a refresh that already has a value keeps the prior
    /// figure on screen until the new one lands — no "Calculating…" flash on every refocus.
    /// `.utility` priority keeps the background size calc off the foreground's back.
    ///
    /// Ownership via `measureGeneration`: each walk captures the generation it was launched
    /// under and only mutates the shared `isMeasuring`/`cacheBytes` while it is still the
    /// current walk. A superseded walk — a newer `refreshSize()` has since run, or the delete
    /// path cancelled this one and spawned a fresh walk — bails without clearing `isMeasuring`
    /// (which now belongs to that newer walk) or overwriting `cacheBytes`. Without this a
    /// late-resuming cancelled walk could clear the coalescing flag mid-walk, letting a later
    /// refocus spawn a second concurrent, untracked walk.
    private func refreshSize() {
        guard !manager.isRemovingData, !isMeasuring else { return }
        isMeasuring = true
        measureGeneration += 1
        let generation = measureGeneration
        refreshTask = Task(priority: .utility) {
            let bytes = await manager.currentCacheSize()
            // Only the current walk owns the shared flag/value; a superseded walk stops here.
            guard generation == measureGeneration else { return }
            isMeasuring = false
            guard !Task.isCancelled else { return }
            cacheBytes = bytes
        }
    }
}

#Preview {
    ContentView(manager: TranscriptionManager())
}
