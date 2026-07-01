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

    // MARK: State

    var droppedFileURLs: [URL] = []
    var selectedLanguage: TranscriptionLanguage = .auto
    var selectedModel: WhisperModel = .base
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

            var allText = ""
            let total = droppedFileURLs.count

            for (index, url) in droppedFileURLs.enumerated() {
                let audioURL = try await prepareAudio(from: url)

                var options = DecodingOptions()
                if selectedLanguage != .auto {
                    options.language = selectedLanguage.code
                }

                let results = try await kit.transcribe(
                    audioPath: audioURL.path,
                    decodeOptions: options
                )
                let text = results.map(\.text).joined(separator: " ")

                if total > 1 {
                    allText += "--- \(url.lastPathComponent) ---\n"
                }
                allText += text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Remove `directory` and report whether it was actually removed: `true` when the
    /// directory existed and `removeItem` succeeded, `false` when it was already absent or
    /// removal failed. Best-effort — never throws. Reports removal (not bytes) so callers can
    /// key the engine reset off "the cache is gone" rather than a byte count, which would
    /// misfire for a removed-but-fileless tree (e.g. a partial download). `nonisolated
    /// static` for the same off-actor / testability reasons as `cacheSize(of:)`.
    @discardableResult
    nonisolated static func deleteCache(at directory: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            return false
        }
    }

    /// Off-main-actor, cancellation-aware size walk. Unlike `Task.detached`, a
    /// `nonisolated async` function runs on the cooperative pool while staying in the
    /// caller's structured task tree (SE-0338) — so cancelling the caller (a superseded
    /// `refreshSize()` task) propagates into `cacheSize`'s loop and aborts the walk
    /// instead of leaving it to run to completion. Distinct name (not an async overload
    /// of `cacheSize`) so the call below can't re-resolve to itself and recurse.
    private nonisolated static func cacheSizeOffActor(of directory: URL) async -> Int64 {
        cacheSize(of: directory)
    }

    /// Bytes currently occupied by the downloaded model cache. The filesystem walk runs
    /// off the main actor and is cancellable (see `cacheSizeOffActor`).
    func currentCacheSize() async -> Int64 {
        await Self.cacheSizeOffActor(of: Self.modelCacheDirectory)
    }

    /// Delete all downloaded models, reporting whether the cache directory was actually
    /// removed. Refuses (returns `false`) while a transcription is in flight — deleting model
    /// files out from under a live `transcribe(...)` would corrupt the run — or while another
    /// delete is already going. When the cache was removed the in-memory engine is dropped
    /// (`whisperKit`/`loadedModel` reset) so the next `startTranscription()` takes the
    /// `whisperKit == nil` path and re-downloads cleanly; a no-op delete (cache already
    /// absent) leaves a loaded engine alone. `status` is deliberately left untouched: deletion is an
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
        let removed = await Task.detached(priority: .utility) {
            Self.deleteCache(at: directory)
        }.value
        // Only drop the in-memory engine when the cache was actually removed; a no-op delete
        // (cache already absent) shouldn't force a needless reload/re-download.
        if removed {
            whisperKit = nil
            loadedModel = nil
        }
        isDeletingModels = false
        return removed
    }
}

#if DEBUG
extension TranscriptionManager {
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
