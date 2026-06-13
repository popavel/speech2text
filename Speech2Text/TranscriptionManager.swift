import Foundation
@preconcurrency import WhisperKit
import AVFoundation

// MARK: - Language

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto = ""
    case english = "en"
    case german = "de"
    case russian = "ru"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case japanese = "ja"
    case chinese = "zh"
    case ukrainian = "uk"

    var id: String { rawValue + displayName }

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .german: return "Deutsch"
        case .russian: return "Русский"
        case .french: return "Français"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .japanese: return "日本語"
        case .chinese: return "中文"
        case .ukrainian: return "Українська"
        }
    }
}

// MARK: - Model

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largeTurbo = "openai_whisper-large-v3-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (~75 MB, fastest)"
        case .base: return "Base (~142 MB)"
        case .small: return "Small (~466 MB)"
        case .largeTurbo: return "Large V3 Turbo (~1.5 GB, best)"
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
    private(set) var loadedModel: String?

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

    var canTranscribe: Bool {
        !droppedFileURLs.isEmpty && !isProcessing
    }

    var statusMessage: String {
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
        "mp3", "wav", "m4a", "flac", "aac", "ogg", "wma", "aiff", "caf",
    ]

    nonisolated static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "avi", "m4v",
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
                whisperKit = try await WhisperKit(model: modelName)
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
                    options.language = selectedLanguage.rawValue
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
