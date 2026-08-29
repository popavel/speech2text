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

    /// Number of distinct spoken languages offered: unique WhisperKit language codes, excluding the
    /// Auto-detect pseudo-entry (whose code is ""). Aliases that share a code (e.g. "mandarin"/"chinese")
    /// count once. Lives here — not in help copy — so the Auto-detect exclusion is unit-tested, matching
    /// how `matching`/`submitSelection` keep language logic on the type.
    static let spokenLanguageCount: Int = Set(allCases.map(\.code)).subtracting([""]).count
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

    /// The model's user-facing name in two parts, so `shortName` and `displayName` project from a
    /// single per-case source and can't drift. `short` is the bare name (used where prose names one
    /// model, e.g. the help book's "… is a good default"); `detail` is the parenthetical size/speed
    /// note. Kept as one switch rather than two parallel `shortName`/`displayName` switches that
    /// could fall out of sync.
    private var nameParts: (short: String, detail: String) {
        switch self {
        case .tiny: return ("Tiny", "~75 MB, fastest")
        case .base: return ("Base", "~142 MB")
        case .small: return ("Small", "~466 MB")
        case .largeTurbo: return ("Large V3 Turbo", "~1.5 GB, fast")
        case .largeV3: return ("Large V3", "~2.9 GB, most accurate")
        }
    }

    /// The bare model name, without the size/speed note.
    var shortName: String { nameParts.short }

    /// The full picker label: the short name followed by its parenthetical detail. Composed from
    /// `nameParts`, so it always begins with `shortName` by construction.
    var displayName: String { "\(nameParts.short) (\(nameParts.detail))" }
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
    /// The model download reported no progress for this long — see `withStallWatchdog`. Carries the
    /// window so the message names it without the number drifting from `modelDownloadIdleTimeout`.
    case modelDownloadStalled(Duration)
    /// The model download failed outright. Wraps the underlying error's text, which is otherwise
    /// unreadable: Hub's errors are plain Swift enums, so their `localizedDescription` is the
    /// useless "The operation couldn't be completed."
    case modelDownloadFailed(String)
    /// Loading the downloaded model hit its ceiling — see `modelLoadCeiling`. Distinct from
    /// `modelDownloadStalled` because the user's next move differs: nothing is left to resume, and
    /// the likeliest cause is the tokenizer fetch inside `loadModels()` hanging.
    case modelLoadTimedOut(Duration)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "No audio track found in the video file"
        case .audioExtractionFailed: return "Failed to extract audio from the video file"
        case .unsupportedFormat(let ext):
            return ext.isEmpty
                ? "Unsupported file format: file has no extension"
                : "Unsupported file format: .\(ext)"
        case .modelDownloadStalled(let idle):
            let minutes = max(1, idle.components.seconds / 60)
            return """
                Model download stalled: no progress for \(minutes) minute\(minutes == 1 ? "" : "s"). \
                Check your connection and try again — if it keeps failing, delete the downloaded \
                models in Settings and start over
                """
        case .modelDownloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .modelLoadTimedOut(let ceiling):
            let minutes = max(1, ceiling.components.seconds / 60)
            return """
                Loading the model took longer than \(minutes) minute\(minutes == 1 ? "" : "s") and \
                was given up on. Check your connection — the first load of a model also fetches its \
                tokenizer — and try again
                """
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

        /// Every persisted-setting key, so the complete-uninstall wipe (`removeAllAppData`) can't
        /// drift from what the app actually persists. Add a new setting's key here too.
        static let all = [language, model, task, temperature]
    }

    /// The code defaults for the four persisted settings — the single source of truth shared by the
    /// property initializers below and `restoreDefaults()`, so a changed default can't silently
    /// diverge between a fresh launch and Restore. Also the value an absent/invalid persisted entry
    /// falls back to: the initializer runs, then `loadPersistedSettings` leaves it in place.
    enum Defaults {
        static let task: DecodingTask = .transcribe
        static let model: WhisperModel = .base
        static let temperature: Float = 0.0
        static let language: TranscriptionLanguage = .auto
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPersistedSettings()
    }

    /// Overlay any persisted settings onto the declared defaults. Absent or invalid values leave
    /// both the in-memory default AND the stored value untouched — e.g. a model id no longer offered
    /// after an app update, or a language WhisperKit has dropped, stays on disk so it resolves again
    /// if that entry returns (rather than being erased to `.auto` on a mere launch). Called once from
    /// `init`; each *successful* assignment is idempotent with the property's `didSet` (it writes
    /// back the value just read).
    private func loadPersistedSettings() {
        if let raw = defaults.string(forKey: Keys.model), let model = WhisperModel(rawValue: raw) {
            selectedModel = model
        }
        if let code = defaults.string(forKey: Keys.task), let task = DecodingTask(persistenceCode: code) {
            selectedTask = task
        }
        if let id = defaults.string(forKey: Keys.language),
           let language = TranscriptionLanguage.allCases.first(where: { $0.id == id }) {
            selectedLanguage = language
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
        selectedTask = Defaults.task
        selectedModel = Defaults.model
        temperature = Defaults.temperature
        selectedLanguage = Defaults.language
    }

    // MARK: State

    var droppedFileURLs: [URL] = []
    /// Persisted across launches (like `selectedModel`/`selectedTask`/`temperature`) via `didSet` →
    /// `defaults`. The row *id* (`displayName`, unique per entry) is what gets stored, so an alias
    /// that shares a `code` (e.g. Mandarin vs Chinese) round-trips to the exact chosen row; `.auto`
    /// stores its `"Auto-detect"` id. See `loadPersistedSettings`.
    var selectedLanguage: TranscriptionLanguage = Defaults.language {
        didSet { defaults.set(selectedLanguage.id, forKey: Keys.language) }
    }
    var selectedModel: WhisperModel = Defaults.model {
        didSet { defaults.set(selectedModel.rawValue, forKey: Keys.model) }
    }
    /// Transcribe (keep source language) vs translate-to-English. Projected straight onto
    /// `DecodingOptions.task`; `.translate` always targets English regardless of `selectedLanguage`
    /// (which names the *source*). Uses WhisperKit's own `CaseIterable` enum so the picker is a
    /// zero-maintenance mirror, like `TranscriptionLanguage`.
    var selectedTask: DecodingTask = Defaults.task {
        didSet { defaults.set(selectedTask.persistenceCode, forKey: Keys.task) }
    }
    /// Decoding temperature. `0.0` = greedy/most accurate; higher adds randomness. Exposed behind
    /// the UI's Advanced disclosure — for transcription 0 is almost always best, and WhisperKit's
    /// real use of temperature is the internal fallback ladder on failed segments.
    var temperature: Float = Defaults.temperature {
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
    /// `loadModel(named:)` (cleared before the new engine loads, set once it has) and
    /// `wipeDirectory` (reset after a removal empties the cache).
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

    /// Distinguishes the two destructive removals so the status display can name the right one:
    /// a models-only delete vs the complete-uninstall wipe. Each case owns its user-facing message.
    enum DeletionKind {
        case models
        case allData

        var message: String {
            switch self {
            case .models: return "Deleting downloaded models..."
            case .allData: return "Removing all app data..."
            }
        }
    }

    /// Which destructive removal is in flight, or `nil` when none is. The single source of truth for
    /// the deletion busy-state — it drives `canTranscribe`, the `isRemovingData` guard, and the
    /// status display (each case owns its message). Deliberately **not** derived from `status`:
    /// "a transcription result" and "a removal is running" are orthogonal, and piggybacking on
    /// `status` let any status write (e.g. `clearFiles()` → `.idle`) silently drop the guard
    /// mid-removal. Internal set so tests can simulate the in-flight state; production mutates it
    /// only in `wipeDirectory`.
    var deletion: DeletionKind?

    /// Whether a destructive removal (model-cache delete or full app-data wipe) is in flight.
    /// Computed from `deletion` so the many read-only call sites that only need the yes/no
    /// busy-state — `canTranscribe` and the Storage buttons — stay unchanged.
    var isRemovingData: Bool { deletion != nil }

    var canTranscribe: Bool {
        !droppedFileURLs.isEmpty && !isProcessing && !isRemovingData
    }

    var statusMessage: String {
        // A removal overrides the session status in the display: it can run on top of any
        // status (e.g. a `.completed` result), and `status` is intentionally left untouched
        // during the removal, so `deletion` — not `status` — owns the in-progress message.
        if let deletion { return deletion.message }
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
                try await loadModel(named: modelName)
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
                    allText += Self.batchHeader(forFileNamed: url.lastPathComponent) + "\n"
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

    /// Download and load `modelName`, replacing any engine already loaded.
    ///
    /// This is `WhisperKit(model:downloadBase:)` taken apart into its two phases so the download
    /// half can be watched. It is a faithful split, not a reinterpretation: with a non-nil `model`,
    /// WhisperKit's own `setupModels` passes the name straight to `WhisperKit.download(variant:)`
    /// with these same repo/endpoint defaults, and constructing with `download: false` and no
    /// `modelFolder` is a no-op rather than an error. `downloadBase` keeps models in our app-owned
    /// Application Support folder (see `modelCacheDirectory`) instead of the Hub default
    /// `~/Documents/huggingface`.
    ///
    /// **Both phases are bounded, but not in the same way.** The download reports progress, so it
    /// gets a true stall watchdog: slow is fine, silent is not. `loadModels()` cannot be watched
    /// that way — it reports nothing a watchdog could read, and Core ML specialization is
    /// legitimately slow the first time a model meets a chip — so it gets a plain ceiling instead,
    /// deliberately far beyond any real load.
    ///
    /// It needs one: `loadModels()` is NOT purely local. It ends in `loadTokenizerIfNeeded()`,
    /// which falls back to fetching the tokenizer from the Hub whenever no local `tokenizer.json`
    /// is found — the normal first-run case. That download can wedge exactly like the model
    /// download can, and it would pin `.loadingModel` forever. A half-hour ceiling is a poor error
    /// message but a correct backstop: the busy flag clears, so the UI and Sparkle's
    /// relaunch-postpone loop both come back.
    ///
    /// Splitting the phases also moves loading INTO `.loadingModel`, where the status line already
    /// claims it happens. WhisperKit defers loading to the first `transcribe(...)` call otherwise —
    /// same work, but reported as transcription progress. `transcribe` won't reload what is already
    /// loaded, so nothing happens twice.
    ///
    /// Assignment is deliberately last: a partial download leaves a snapshot that `loadModels()`
    /// rejects, and caching a half-built engine would make every later run fail the same way from
    /// the "already loaded" fast path.
    private func loadModel(named modelName: String) async throws {
        let ticker = ProgressTicker()
        let downloadBase = Self.modelCacheDirectory

        let modelFolder: URL
        do {
            modelFolder = try await Self.withStallWatchdog(
                idle: Self.modelDownloadIdleTimeout,
                poll: Self.modelDownloadPollInterval,
                ticker: ticker,
                drain: Self.modelDownloadDrain
            ) {
                do {
                    return try await WhisperKit.download(
                        variant: modelName,
                        downloadBase: downloadBase
                    ) { _ in ticker.tick() }
                } catch {
                    throw TranscriptionError.modelDownloadFailed(String(describing: error))
                }
            }
        } catch let timeout as StallTimeout {
            throw TranscriptionError.modelDownloadStalled(timeout.idle)
        }

        let kit = try await WhisperKit(
            WhisperKitConfig(
                model: modelName,
                downloadBase: downloadBase,
                load: false,
                download: false
            )
        )
        kit.modelFolder = modelFolder

        // Release the engine we're replacing BEFORE the new one allocates its weights. Holding
        // both across the load would roughly double peak memory on a model switch — the old code
        // never did, because it left loading to the first `transcribe(...)`, by which point the
        // old engine was already gone. On failure this leaves no engine loaded, which costs a
        // reload from the on-disk cache and keeps `loadedModel` honest about what's in memory.
        //
        // This covers the ordinary switch, not the ceiling timeout below: an abandoned
        // `loadModels()` keeps `kit` alive until it finishes on its own, so a retry after that
        // rare failure really can hold two sets of weights. Core ML loading isn't cancellable in
        // any way we could rely on, so there is nothing better to do than let it finish.
        whisperKit = nil
        loadedModel = nil

        do {
            // Nothing ticks this one: Core ML reports no progress, so the watchdog degenerates
            // into the plain ceiling this phase wants. See the doc comment above.
            try await Self.withStallWatchdog(
                idle: Self.modelLoadCeiling,
                poll: Self.modelDownloadPollInterval,
                ticker: ProgressTicker()
            ) {
                try await kit.loadModels()
            }
        } catch let timeout as StallTimeout {
            throw TranscriptionError.modelLoadTimedOut(timeout.idle)
        }

        whisperKit = kit
        loadedModel = modelName
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

    /// The separator header written before each file's transcript in a multi-file batch run
    /// (emitted only when more than one file is queued). Extracted as `nonisolated static` so the
    /// help book can document the exact format by calling it rather than restating the literal.
    nonisolated static func batchHeader(forFileNamed name: String) -> String {
        "--- \(name) ---"
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

    /// The app's bundle identifier — the single source of truth for every on-disk path segment the
    /// app owns. Hard-coded (mirrors `PRODUCT_BUNDLE_IDENTIFIER`) rather than read from `Bundle.main`
    /// so the path is identical under the test host, which runs in a different bundle. Referenced by
    /// `appSupportDirectory` and by the uninstall guide's leftover-path list so they can't drift.
    nonisolated static let bundleIdentifier = "com.speech2text.app"

    /// The app-owned root under Application Support — `~/Library/Application Support/com.speech2text.app`.
    /// The single home for everything the app writes there: the `models/` cache lives beneath it, and the
    /// complete-uninstall wipe (`removeAllAppData`) removes this whole folder. `modelCacheDirectory`
    /// derives from it, so the download path and both cleanup paths can't drift apart.
    ///
    /// `create: false`: reading a path shouldn't have the side effect of creating the folder.
    /// WhisperKit/Hub creates the tree on demand when it actually downloads. The bundle-id segment is
    /// `bundleIdentifier` (hard-coded there rather than read from `Bundle.main`, so the path is
    /// identical under the test host).
    nonisolated static var appSupportDirectory: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// App-owned directory where WhisperKit models are downloaded. Passed as `downloadBase` when
    /// constructing WhisperKit (see `startTranscription()`) so models live under Application Support —
    /// the macOS-sanctioned home for app-managed data — instead of polluting the user's
    /// `~/Documents/huggingface`. Derives from `appSupportDirectory`, the single source of truth for
    /// the app's on-disk footprint, so the download path and the cleanup paths can't drift apart.
    nonisolated static var modelCacheDirectory: URL {
        appSupportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// How long the model download may report no progress before it is treated as wedged (see
    /// `withStallWatchdog`). Bounds `isProcessing`, which is what a stalled download would
    /// otherwise pin true for the life of the process.
    ///
    /// Half an hour, and **do not tighten it** — the window is not a guess, it is arithmetic.
    ///
    /// WhisperKit's Hub downloader reports progress only when it flushes a **10 MB** chunk, so this
    /// window sets a hard throughput floor of 10 MB per window: ~5.7 KB/s (≈46 kbps) at half an
    /// hour, but ~17.5 KB/s (≈140 kbps) at ten minutes. A link under the floor is declared stalled
    /// no matter how healthy it is — and, because Hub's resume state also only advances per flushed
    /// chunk, every retry restarts from the same boundary, so the model becomes permanently
    /// undownloadable rather than merely slow. That is the exact inversion of this watchdog's
    /// purpose ("slow is fine, silent is not"), so the floor has to sit below any link someone
    /// might plausibly be waiting on: even the 75 MB `tiny` model is a multi-hour download at
    /// 46 kbps.
    ///
    /// Silence isn't only about bandwidth either. The repo file listing and the per-file metadata
    /// requests that precede each download emit nothing, and neither does the hash verification of
    /// an already-cached snapshot — sweeps whose duration scales with file count and latency.
    ///
    /// The cost of being generous is only how long a genuinely wedged download takes to report.
    /// Fast failure was never the goal here; a bounded busy flag is.
    nonisolated static let modelDownloadIdleTimeout: Duration = .seconds(1800)

    /// How often the watchdog checks for silence. Granularity, not precision — there is no reason
    /// to notice a half-hour stall within less than a few seconds.
    nonisolated static let modelDownloadPollInterval: Duration = .seconds(5)

    /// How long a stalled download is given to actually stop before the failure is reported.
    ///
    /// Generous on purpose. Both recoveries the error message invites — retry, or delete the
    /// downloaded models — write to the same snapshot directory an orphaned downloader may still
    /// be writing to, and this is the window that makes that overlap unlikely rather than likely:
    /// the user cannot read the message, open Settings and click Delete inside it. Thirty seconds
    /// is invisible next to the half-hour stall that preceded it.
    ///
    /// It is a shrunk window, not a lock. The alternative — refusing deletes while an orphan is
    /// unaccounted for — would gate the recovery path on a task that by definition might never
    /// finish, which is the same class of wedge this whole file exists to remove.
    nonisolated static let modelDownloadDrain: Duration = .seconds(30)

    /// Hard ceiling on `WhisperKit.loadModels()`. Not a stall window — that phase reports nothing
    /// to watch — so it has to clear the slowest legitimate case by a wide margin: a first-ever
    /// Core ML specialization of the largest model on the oldest supported chip, minutes rather
    /// than tens of minutes. Half an hour is far past that, which is the point: it never fires on
    /// slow hardware, and it still guarantees `.loadingModel` ends. It exists because that phase
    /// also fetches the tokenizer from the Hub on first run (see `loadModel(named:)`), so it can
    /// wedge on the network like the download can.
    nonisolated static let modelLoadCeiling: Duration = .seconds(1800)

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

    /// Shared machinery for the two destructive removals (`deleteAllModels`, `removeAllAppData`).
    /// Refuses (returns `nil`, nothing touched) while a transcription is in flight — removing files
    /// out from under a live `transcribe(...)` would corrupt the run — or while another removal is
    /// already going. Marks the busy-state (`deletion`) **synchronously** before the first
    /// suspension, so a transcription started concurrently (also on the main actor) sees
    /// `canTranscribe == false` and can't begin reading/writing the directory while it is being
    /// removed; because `deletion` is independent of `status`, a concurrent `clearFiles()`
    /// (→ `.idle`) can't drop the guard mid-removal. The blocking `removeItem` runs to completion
    /// off the @MainActor via `Task.detached` — a half-removed tree is worse than a finished one,
    /// and `removeItem` isn't cancellation-aware — capturing existence in the same hop. The
    /// in-memory engine is dropped whenever the directory **existed** before the attempt (not only
    /// on full success): a partial removal (children unlinked but the final node removal failed) can
    /// still have deleted the weight files, leaving a loaded engine pointing at missing files, which
    /// would let the next `startTranscription()` take the "already loaded" fast path against a gutted
    /// cache. Only a genuine no-op (directory already absent) leaves a loaded engine alone. `status`
    /// is deliberately left untouched: a removal is orthogonal, owned by `deletion`. Returns whether
    /// the directory was *fully* removed — so Settings re-walks and surfaces residual bytes on a
    /// partial failure rather than publishing 0 — or `nil` when the guard refused and nothing was
    /// touched (distinct from `false`, a real attempt that didn't fully remove). `kind` selects the
    /// status message shown for the duration.
    private func wipeDirectory(_ directory: URL, kind: DeletionKind) async -> Bool? {
        guard !isProcessing, deletion == nil else { return nil }
        deletion = kind
        // Capture existence and remove in the same detached hop, so both stay off the @MainActor.
        let result = await Task.detached(priority: .utility) { () -> (existed: Bool, removed: Bool) in
            let existed = FileManager.default.fileExists(atPath: directory.path)
            return (existed, Self.deleteCache(at: directory))
        }.value
        // Drop the engine whenever the directory existed before the attempt — even a partial removal
        // may have unlinked the weight files, so a loaded engine would now be stale.
        if result.existed {
            whisperKit = nil
            loadedModel = nil
        }
        deletion = nil
        return result.removed
    }

    /// Delete all downloaded models, reporting whether the cache directory was *fully* removed.
    /// Thin wrapper over `wipeDirectory`: refuses (`false`) while a transcription or another removal
    /// is in flight, drops the engine when the cache existed, and reports full removal so Settings
    /// re-walks residual bytes on a partial failure. `directory` is injectable for hermetic tests.
    @discardableResult
    func deleteAllModels(from directory: URL = TranscriptionManager.modelCacheDirectory) async -> Bool {
        await wipeDirectory(directory, kind: .models) ?? false
    }

    /// Complete-uninstall wipe: remove the **entire** app-owned Application Support folder
    /// (`appSupportDirectory`, which contains `models/` and any future app data) AND clear the
    /// persisted settings, returning whether the folder was fully removed. This is the in-app half of
    /// a graceful uninstall — macOS has no uninstaller hook and the app isn't sandboxed, so nothing is
    /// reaped when it's trashed. Wider than `deleteAllModels` (which targets only `models/`); both
    /// route the file removal through `wipeDirectory`.
    ///
    /// Settings are cleared through the injected `UserDefaults` (`removeObject`), NOT by deleting the
    /// `.plist` file: writes are mediated by `cfprefsd`, which would just re-materialize the file from
    /// its in-memory cache after a raw delete. Using the injected store also keeps this hermetic under
    /// the app-hosted test process (never touching the developer's real `.standard` domain).
    /// `restoreDefaults()` is deliberately NOT called afterward — its `didSet` writers would
    /// immediately re-persist the keys just cleared. In-memory values are left as they are; a relaunch
    /// loads the code defaults from the now-empty store. The settings clear runs after `wipeDirectory`
    /// returns and is synchronous (no `await` before it), so it can't interleave with a concurrent
    /// transcription; it still runs on a no-op removal (folder already absent) because settings live
    /// independently of the folder. `appSupport` is injectable so the removal can be unit-tested
    /// against a temp dir instead of the real folder.
    @discardableResult
    func removeAllAppData(appSupport: URL = TranscriptionManager.appSupportDirectory) async -> Bool {
        // `nil` means the guard refused (mid-transcription/mid-removal) — leave settings intact.
        guard let removed = await wipeDirectory(appSupport, kind: .allData) else { return false }
        // Clear the persisted settings through the API so cfprefsd actually drops them.
        for key in Keys.all {
            defaults.removeObject(forKey: key)
        }
        return removed
    }
}

extension TranscriptionManager {
    /// The launch argument XCUITest passes to mark a UI-test run.
    ///
    /// Deliberately **outside** the `#if DEBUG` below. Both seam functions there are compiled out of
    /// Release, but `SparkleUpdaterModel.shouldStartUpdater` reads this same sentinel
    /// unconditionally — that check is reachable *only* in Release (a Debug build is refused a line
    /// earlier), so a Debug-only constant would not compile for its one real caller.
    ///
    /// One half of a two-target contract: `Speech2TextUITests` is a separate process that links no
    /// app symbols, so `launchApp()` hardcodes the same string with nothing in the compiler tying
    /// the two together. Renaming the *identifier* is safe — that is an ordinary compiler-checked
    /// refactor. Changing the *value* is what silently breaks the seam and the updater gate on a
    /// UI-test launch, and it obliges an edit to that file too.
    /// `uiTestingLaunchArgumentIsTheCrossTargetContract` catches that from this side only: it pins
    /// this constant to the literal XCUITest sends, so an app-side value change fails the unit
    /// suite. The reverse — editing the literal over there — is caught by nothing but running the
    /// UI tests.
    nonisolated static let uiTestingLaunchArgument = "-uiTesting"
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
        guard arguments.contains(Self.uiTestingLaunchArgument) else { return .standard }
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
        // Sentinel produced by Speech2TextUITests.launchApp(), which spells the same string out
        // as a literal because that target links no app symbols — see the constant's note on the
        // cross-target half of that contract.
        guard arguments.contains(Self.uiTestingLaunchArgument) else { return }

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
