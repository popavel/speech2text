import Foundation
@preconcurrency import WhisperKit
import AVFoundation

// MARK: - Language

/// A selectable transcription language, projected directly from WhisperKit's
/// `Constants.languages`. Every WhisperKit name becomes an entry, so the list is a
/// zero-maintenance mirror of the engine's supported set (it never drifts). WhisperKit
/// lists a handful of alias names (e.g. "mandarin"/"chinese") that share a `code`;
/// those simply appear as separate rows mapping to the same code.
struct TranscriptionLanguage: Identifiable, Hashable, Sendable {
    let code: String        // "" = auto-detect, else a WhisperKit language code (may repeat across aliases)
    let displayName: String // unique per entry (the WhisperKit name, capitalized)

    var id: String { displayName }   // displayName is unique per entry

    static let auto = TranscriptionLanguage(code: "", displayName: "Auto-detect")

    /// Auto-detect first, then every WhisperKit language sorted A–Z by display name.
    static let allCases: [TranscriptionLanguage] = {
        let derived = Constants.languages
            .map { TranscriptionLanguage(code: $0.value, displayName: $0.key.capitalized) }
            .sorted { $0.displayName < $1.displayName }
        return [.auto] + derived
    }()

    /// Languages whose display name contains `query` (case-insensitive substring); a blank
    /// query (empty or whitespace-only) returns the full list. The UI's `LanguagePicker`
    /// reads from this so the filter is exercised by tests, not buried in the view.
    ///
    /// `lowercased()` (no `with:` locale) is Unicode default case folding, which is
    /// locale-independent — so this avoids the Turkish/Azerbaijani dotless-i hazard
    /// ('I'↔'ı') without needing to pin a locale.
    static func matching(_ query: String) -> [TranscriptionLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allCases }
        let lowercasedQuery = trimmed.lowercased()
        return allCases.filter { $0.displayName.lowercased().contains(lowercasedQuery) }
    }

    /// The language to commit when the user presses Return in the search field: the
    /// top match for a real query, or `nil` for a blank (empty/whitespace) query.
    /// Lives here (not in the view) so the "blank Return selects nothing" rule is
    /// tested directly — without it, `matching("").first` is `.auto`, so Return on an
    /// empty field would silently reset the current selection to Auto-detect.
    static func submitSelection(for query: String) -> TranscriptionLanguage? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return matching(query).first
    }
}

// MARK: - Task

extension DecodingTask {
    /// User-facing label for the transcribe/translate picker. `.translate` always produces
    /// English output, so the label says so explicitly.
    var displayName: String {
        switch self {
        case .transcribe: return "Transcribe"
        case .translate: return "Translate to English"
        }
    }

    /// Stable string used to persist the task in `UserDefaults`. `DecodingTask` is WhisperKit's
    /// own enum and is not `RawRepresentable`, so we map its two cases explicitly rather than
    /// leaning on `description` (whose format WhisperKit could change out from under us).
    var persistenceCode: String { self == .translate ? "translate" : "transcribe" }

    init?(persistenceCode: String) {
        switch persistenceCode {
        case "transcribe": self = .transcribe
        case "translate": self = .translate
        default: return nil
        }
    }
}

// MARK: - Model

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largeTurbo = "openai_whisper-large-v3_turbo"
    case largeV3 = "openai_whisper-large-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (~75 MB, fastest)"
        case .base: return "Base (~142 MB)"
        case .small: return "Small (~466 MB)"
        case .largeTurbo: return "Large V3 Turbo (~1.5 GB, fast)"
        case .largeV3: return "Large V3 (~2.9 GB, most accurate)"
        }
    }
}

// MARK: - Status

enum TranscriptionStatus: Equatable {
    case idle
    case loadingModel
    case transcribing(progress: Double)
    case completed
    case error(String)
}

// MARK: - Errors

enum TranscriptionError: LocalizedError, Equatable {
    case noAudioTrack
    case audioExtractionFailed
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "No audio track found in the video file"
        case .audioExtractionFailed: return "Failed to extract audio from the video file"
        case .unsupportedFormat(let ext):
            return ext.isEmpty
                ? "Unsupported file format: file has no extension"
                : "Unsupported file format: .\(ext)"
        }
    }
}

// MARK: - Manager

@MainActor
@Observable
class TranscriptionManager {

    // MARK: Persistence

    /// Backing store for the persisted user settings (task, language, model, temperature).
    /// Injectable so tests use an ephemeral domain instead of `.standard`: the unit-test host
    /// shares the app's bundle id, so writing real settings from tests would be cross-talk.
    private let defaults: UserDefaults

    /// `UserDefaults` keys for the persisted settings. Internal (not private) so tests can seed a
    /// raw/invalid value and assert the load path's fallbacks.
    enum Keys {
        static let language = "settings.selectedLanguage"
        static let model = "settings.selectedModel"
        static let task = "settings.selectedTask"
        static let temperature = "settings.temperature"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPersistedSettings()
    }

    /// Overlay any persisted settings onto the declared defaults. Absent or invalid values leave
    /// the code default in place — e.g. a model id no longer offered after an app update, or a
    /// language WhisperKit has dropped (→ `.auto`). Called once from `init`; assigning here is
    /// idempotent with the properties' `didSet` (it writes back the value just read).
    private func loadPersistedSettings() {
        if let raw = defaults.string(forKey: Keys.model), let model = WhisperModel(rawValue: raw) {
            selectedModel = model
        }
        if let code = defaults.string(forKey: Keys.task), let task = DecodingTask(persistenceCode: code) {
            selectedTask = task
        }
        if let id = defaults.string(forKey: Keys.language) {
            selectedLanguage = TranscriptionLanguage.allCases.first { $0.id == id } ?? .auto
        }
        if defaults.object(forKey: Keys.temperature) != nil {
            temperature = defaults.float(forKey: Keys.temperature)
        }
    }

    /// Reset the four user settings to their defaults: Transcribe, Base model, temperature 0,
    /// Auto-detect language. Each assignment's `didSet` re-persists, so the store reflects the reset
    /// too. Does not touch the loaded engine — the model only (re)loads on the next
    /// `startTranscription`, so restoring `.base` never triggers a download from here.
    func restoreDefaults() {
        selectedTask = .transcribe
        selectedModel = .base
        temperature = 0.0
        selectedLanguage = .auto
    }

    // MARK: State

    var droppedFileURLs: [URL] = []
    /// Persisted across launches (like `selectedModel`/`selectedTask`/`temperature`) via `didSet` →
    /// `defaults`. The row *id* (`displayName`, unique per entry) is what gets stored, so an alias
    /// that shares a `code` (e.g. Mandarin vs Chinese) round-trips to the exact chosen row; `.auto`
    /// stores its `"Auto-detect"` id. See `loadPersistedSettings`.
    var selectedLanguage: TranscriptionLanguage = .auto {
        didSet { defaults.set(selectedLanguage.id, forKey: Keys.language) }
    }
    var selectedModel: WhisperModel = .base {
        didSet { defaults.set(selectedModel.rawValue, forKey: Keys.model) }
    }
    /// Transcribe (keep source language) vs translate-to-English. Projected straight onto
    /// `DecodingOptions.task`; `.translate` always targets English regardless of `selectedLanguage`
    /// (which names the *source*). Uses WhisperKit's own `CaseIterable` enum so the picker is a
    /// zero-maintenance mirror, like `TranscriptionLanguage`.
    var selectedTask: DecodingTask = .transcribe {
        didSet { defaults.set(selectedTask.persistenceCode, forKey: Keys.task) }
    }
    /// Decoding temperature. `0.0` = greedy/most accurate; higher adds randomness. Exposed behind
    /// the UI's Advanced disclosure — for transcription 0 is almost always best, and WhisperKit's
    /// real use of temperature is the internal fallback ladder on failed segments.
    var temperature: Float = 0.0 {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }
    var status: TranscriptionStatus = .idle
    var transcriptionResult: String = ""

    /// File names skipped on the last `addFiles` call because their format is
    /// unsupported. Exposed as raw data, not a formatted message, so the view
    /// owns presentation; kept separate from `status` so a partial drop (some
    /// usable files + some junk) is not reported as a hard `.error`.
    private(set) var skippedFileNames: [String] = []

    // MARK: Internal

    private var whisperKit: WhisperKit?

    /// The model id currently loaded into `whisperKit`, or `nil` when no engine is loaded.
    /// Internal set so tests can simulate a loaded engine; production writes it only in
    /// `startTranscription` (on load) and `deleteAllModels` (reset after the cache is removed).
    var loadedModel: String?

    /// The loaded WhisperKit instance, exposed only as an opaque object so tests
    /// can assert the same-model fast path reuses it (instance identity) rather
    /// than reconstructing it.
    var loadedModelInstance: AnyObject? { whisperKit }

    // MARK: Computed

    var isProcessing: Bool {
        switch status {
        case .loadingModel, .transcribing: return true
        default: return false
        }
    }

    /// Whether a model-cache deletion is in flight. The single source of truth for the
    /// deletion busy-state — it drives both `canTranscribe` and the "Deleting…" display.
    /// Deliberately **not** derived from `status`: "a transcription result" and "the cache
    /// is being deleted" are orthogonal, and piggybacking on `status` let any status write
    /// (e.g. `clearFiles()` → `.idle`) silently drop the guard mid-delete. Internal set so
    /// tests can simulate the in-flight state; production mutates it only in `deleteAllModels`.
    var isDeletingModels = false

    var canTranscribe: Bool {
        !droppedFileURLs.isEmpty && !isProcessing && !isDeletingModels
    }

    var statusMessage: String {
        // A delete overrides the session status in the display: it can run on top of any
        // status (e.g. a `.completed` result), and `status` is intentionally left untouched
        // during the delete, so the flag — not the enum — owns the "Deleting…" message.
        if isDeletingModels { return "Deleting downloaded models..." }
        switch status {
        case .idle: return ""
        case .loadingModel: return "Downloading and loading model (first time may take a while)..."
        case .transcribing(let progress):
            return progress > 0
                ? "Transcribing... \(Int(progress * 100))%"
                : "Transcribing..."
        case .completed: return "Transcription complete"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    // MARK: File Management

    nonisolated static let supportedAudioExtensions: Set<String> = [
        "mp3", "wav", "m4a", "flac", "aac", "ogg", "aiff", "caf",
    ]

    nonisolated static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v",
    ]

    /// Whether a URL's extension names an audio or video container the app can
    /// handle. The single source of truth used both to filter dropped files
    /// (`addFiles`) and to route them (`prepareAudio`).
    enum MediaKind {
        case audio
        case video
    }

    nonisolated static func mediaKind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) { return .video }
        if supportedAudioExtensions.contains(ext) { return .audio }
        return nil
    }

    func addFiles(_ urls: [URL]) {
        var skipped: [String] = []
        for url in urls {
            guard Self.mediaKind(for: url) != nil else {
                skipped.append(url.lastPathComponent)
                continue
            }
            if !droppedFileURLs.contains(where: { $0.path == url.path }) {
                droppedFileURLs.append(url)
            }
        }

        // Surface skipped files as plain data (the view formats the message), not
        // through `status`: a partial drop is a non-blocking notice, not a hard
        // `.error`. Each drop replaces the previous notice.
        skippedFileNames = skipped
    }

    func removeFile(at index: Int) {
        guard droppedFileURLs.indices.contains(index) else { return }
        droppedFileURLs.remove(at: index)
        // Drop the skip notice once the queue is empty so it doesn't linger with
        // nothing left to act on.
        if droppedFileURLs.isEmpty {
            skippedFileNames = []
        }
    }

    func clearFiles() {
        droppedFileURLs.removeAll()
        transcriptionResult = ""
        status = .idle
        skippedFileNames = []
    }

    // MARK: Transcription

    func startTranscription() async {
        guard canTranscribe else { return }

        status = .loadingModel
        transcriptionResult = ""
        // The skip notice described the input that's now being transcribed; clear
        // it so it can't outlive the run (and stack under a later .completed/.error).
        skippedFileNames = []

        do {
            let modelName = selectedModel.rawValue
            if whisperKit == nil || loadedModel != modelName {
                // downloadBase keeps models in our app-owned Application Support folder
                // (see modelCacheDirectory) instead of the Hub default ~/Documents/huggingface.
                whisperKit = try await WhisperKit(model: modelName, downloadBase: Self.modelCacheDirectory)
                loadedModel = modelName
            }

            guard let kit = whisperKit else {
                status = .error("Failed to initialize WhisperKit")
                return
            }

            status = .transcribing(progress: 0)

            // Built once per run (not per file): the options depend only on the current
            // selections, so one snapshot keeps every file in the run consistent (the pickers
            // stay interactive during a run, so a mid-run edit can't split the batch).
            let options = makeDecodingOptions()

            var allText = ""
            let total = droppedFileURLs.count

            for (index, url) in droppedFileURLs.enumerated() {
                let audioURL = try await prepareAudio(from: url)

                let results = try await kit.transcribe(
                    audioPath: audioURL.path,
                    decodeOptions: options
                )
                let text = Self.displayTranscript(joining: results.map(\.text))

                if total > 1 {
                    allText += "--- \(url.lastPathComponent) ---\n"
                }
                allText += text
                allText += "\n\n"

                status = .transcribing(progress: Double(index + 1) / Double(total))

                // Clean up temporary audio file
                if audioURL != url {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }

            transcriptionResult = allText.trimmingCharacters(in: .whitespacesAndNewlines)
            status = .completed
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Build the `DecodingOptions` for a run from the current user selections. Extracted from
    /// `startTranscription` so the state→options mapping is unit-testable without loading a model
    /// or hitting the network. `chunkingStrategy = .vad` is a fixed default (not a user toggle):
    /// VAD splitting improves accuracy and parallelism on long audio. `language` is left `nil`
    /// (WhisperKit auto-detects) unless a specific language is chosen.
    func makeDecodingOptions() -> DecodingOptions {
        var options = DecodingOptions()
        options.task = selectedTask
        options.temperature = temperature
        options.chunkingStrategy = .vad
        if selectedLanguage != .auto {
            options.language = selectedLanguage.code
        }
        return options
    }

    /// Placeholder shown when a file produced no transcript text. `.vad` chunking (always on) has
    /// WhisperKit silently drop chunks whose decode failed — returning fewer/zero results rather
    /// than throwing — and silent audio can also legitimately yield nothing. Either way, surface a
    /// visible marker instead of a blank result that reads as a successful-but-empty run.
    nonisolated static let noSpeechPlaceholder = "[No speech could be transcribed]"

    /// The transcript to display for one file: its per-chunk texts joined and trimmed, or
    /// `noSpeechPlaceholder` when that leaves nothing. Extracted as pure/`nonisolated static` logic
    /// so the "empty → marker" rule is unit-testable without loading a model (like
    /// `makeDecodingOptions`). Input is the raw `TranscriptionResult.text` values for the file.
    nonisolated static func displayTranscript(joining segmentTexts: [String]) -> String {
        let joined = segmentTexts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? noSpeechPlaceholder : joined
    }

    // MARK: Audio Preparation

    func prepareAudio(from url: URL) async throws -> URL {
        switch Self.mediaKind(for: url) {
        case .video:
            return try await extractAudio(from: url)
        case .audio:
            return url
        case nil:
            throw TranscriptionError.unsupportedFormat(url.pathExtension.lowercased())
        }
    }

    func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw TranscriptionError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw TranscriptionError.audioExtractionFailed
        }

        do {
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            // Export may have written a partial file before failing; don't leak it.
            try? FileManager.default.removeItem(at: outputURL)
            throw TranscriptionError.audioExtractionFailed
        }

        return outputURL
    }

    // MARK: - Model Cache / Storage

    /// App-owned directory where WhisperKit models are downloaded. Passed as
    /// `downloadBase` when constructing WhisperKit (see `startTranscription()`) so models
    /// live under Application Support — the macOS-sanctioned home for app-managed data —
    /// instead of polluting the user's `~/Documents/huggingface`. Being the single source
    /// of truth here means the download path and the cleanup path (`deleteAllModels`)
    /// can't drift apart.
    ///
    /// `create: false`: reading a path shouldn't have the side effect of creating the
    /// folder. WhisperKit/Hub creates the tree on demand when it actually downloads.
    /// The bundle-id segment is hard-coded (mirrors `PRODUCT_BUNDLE_IDENTIFIER`) rather
    /// than read from `Bundle.main`, so the path is identical under the test host.
    nonisolated static var modelCacheDirectory: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("com.speech2text.app", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Total bytes on disk under `directory` (recursive sum of regular-file allocated
    /// sizes). Returns 0 when the directory doesn't exist or can't be enumerated.
    /// `nonisolated static` so the recursive walk runs off the `@MainActor` and is
    /// unit-testable against a temp directory with no manager instance or network.
    nonisolated static func cacheSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            // Bail when the enclosing task was cancelled (e.g. a superseded refresh).
            // No-op outside a cancelled task — the unit tests read `Task.isCancelled ==
            // false`, so the full sum is unchanged.
            if Task.isCancelled { return total }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            // totalFileAllocatedSize includes metadata/resource forks; fall back to the
            // plain allocated size if the richer key is unavailable.
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Remove `directory` and report whether it was *fully* removed: `true` when the directory
    /// existed and `removeItem` succeeded outright, `false` when it was already absent or removal
    /// failed. Best-effort — never throws. This boolean cannot distinguish "nothing was there" from
    /// "children were unlinked but the final node removal failed" (`removeItem` recurses depth-first,
    /// so a late failure can leave weight files already gone yet return `false`); callers that need
    /// to know whether the tree was *touched* must check existence separately rather than relying on
    /// this. `nonisolated static` for the same off-actor / testability reasons as `cacheSize(of:)`.
    @discardableResult
    nonisolated static func deleteCache(at directory: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            return false
        }
    }

    /// Bytes currently occupied by the downloaded model cache. `nonisolated` so the
    /// synchronous `cacheSize` walk runs off the @MainActor: under SE-0338 a nonisolated
    /// async member executes on the cooperative pool, not the caller's actor. It stays in
    /// the caller's structured task tree, so a superseded refresh cancelling its task
    /// propagates into `cacheSize`'s `Task.isCancelled` loop and aborts the walk.
    nonisolated func currentCacheSize() async -> Int64 {
        Self.cacheSize(of: Self.modelCacheDirectory)
    }

    /// Delete all downloaded models, reporting whether the cache directory was *fully* removed.
    /// Refuses (returns `false`) while a transcription is in flight — deleting model
    /// files out from under a live `transcribe(...)` would corrupt the run — or while another
    /// delete is already going. The in-memory engine is dropped (`whisperKit`/`loadedModel` reset)
    /// whenever the cache **existed** before the attempt — not only on full success — because a
    /// partial removal (children unlinked but final node removal failed) can still have deleted the
    /// weight files, leaving a loaded engine pointing at missing files; keeping it would let the next
    /// `startTranscription()` take the "already loaded" fast path against a gutted cache. Only a
    /// genuine no-op delete (cache already absent) leaves a loaded engine alone. `status` is deliberately left untouched: deletion is an
    /// orthogonal concern owned by `isDeletingModels`, which drives the display for the
    /// whole delete regardless of what `status` holds. `directory` is injectable so the
    /// removal can be unit-tested against a temp dir instead of the real cache.
    @discardableResult
    func deleteAllModels(from directory: URL = TranscriptionManager.modelCacheDirectory) async -> Bool {
        guard !isProcessing, !isDeletingModels else { return false }
        // Set the busy flag *synchronously*, before the first suspension, so a transcription
        // started concurrently (also on the main actor) sees `canTranscribe == false` and
        // can't begin reading/writing the directory while it is being removed. Because the
        // flag is independent of `status`, a concurrent `clearFiles()` (→ `.idle`) can't
        // drop the guard mid-delete. Cleared once the engine has been dropped.
        isDeletingModels = true
        // Offload the blocking `removeItem` off the @MainActor. Unlike the size walk
        // (`currentCacheSize`, a structured nonisolated hop a superseded refresh can cancel),
        // a destructive delete must run to completion — a half-removed cache is worse than a
        // finished one — so it uses `Task.detached`, deliberately decoupled from caller
        // cancellation. (`removeItem` isn't cancellation-aware anyway.)
        // Capture existence and remove in the same detached hop, so both stay off the @MainActor.
        let result = await Task.detached(priority: .utility) { () -> (existed: Bool, removed: Bool) in
            let existed = FileManager.default.fileExists(atPath: directory.path)
            return (existed, Self.deleteCache(at: directory))
        }.value
        // Drop the in-memory engine whenever the cache existed before the attempt — even a partial
        // removal may have unlinked the weight files, so a loaded engine is now stale. Only a true
        // no-op delete (cache already absent) leaves it alone to avoid a needless reload/re-download.
        if result.existed {
            whisperKit = nil
            loadedModel = nil
        }
        isDeletingModels = false
        // Report *full* removal: on a partial failure the caller (Settings) re-walks and surfaces
        // the residual leftover bytes rather than publishing 0.
        return result.removed
    }
}

#if DEBUG
extension TranscriptionManager {
    /// The `UserDefaults` a UI-test launch should persist settings into: a cleared, volatile suite
    /// isolated from `.standard`. The XCUITest host runs as the real app bundle, so persisting to
    /// `.standard` would make settings-sensitive UI tests non-deterministic (one run's picker
    /// selection would survive into the next) and would clobber the developer's real saved
    /// settings. A normal launch (no `-uiTesting`) gets `.standard`, untouched.
    static func uiTestSettingsStore(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> UserDefaults {
        guard arguments.contains("-uiTesting") else { return .standard }
        let suiteName = "com.speech2text.uitests"
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    /// Reads launch arguments/environment set by XCUITest and seeds state so UI
    /// tests can exercise the interface without a file dialog, drag-and-drop, or
    /// loading WhisperKit (which would download a model). No-op unless launched
    /// with `-uiTesting`, and compiled out of Release builds entirely.
    func applyUITestSeamIfPresent(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // Sentinel produced by Speech2TextUITests.launchApp() (`launchArguments =
        // ["-uiTesting"]`). The two strings must stay in sync — there is no
        // compile-time link across the target boundary.
        guard arguments.contains("-uiTesting") else { return }

        // Preload files without a file dialog. `addFiles` filters by extension
        // only (it never stats the file), so synthetic paths render chips and
        // enable Transcribe without touching disk.
        if let joined = environment["UITEST_PRELOAD_FILES"], !joined.isEmpty {
            let urls = joined
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
            addFiles(urls)
        }

        // Stub a finished transcription so the result UI (editor, Copy, Export)
        // is reachable without running WhisperKit. Guard against an empty value
        // (mirroring the preload guard above) so a blank stub doesn't flip the
        // status to .completed with nothing to show.
        //
        // This jumps straight to the terminal `.completed` state, deliberately
        // skipping most of the side effects the real `startTranscription()` path runs
        // en route (setting `whisperKit`, progress ticks, etc.). It does mirror one
        // `.completed` invariant: clearing `skippedFileNames`, so a mixed preload
        // (supported + unsupported extensions) can't leave the result UI rendered
        // alongside a stale warning row — a state unreachable in the real app. If a
        // future change adds another `.completed` invariant, audit this shortcut too.
        if let stub = environment["UITEST_STUB_RESULT"], !stub.isEmpty {
            skippedFileNames = []   // match startTranscription()'s .completed invariant (see :213)
            transcriptionResult = stub
            status = .completed
        }
    }
}
#endif
