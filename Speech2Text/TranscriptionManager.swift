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

enum TranscriptionError: LocalizedError {
    case noAudioTrack
    case audioExtractionFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "No audio track found in the video file"
        case .audioExtractionFailed: return "Failed to extract audio from the video file"
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

    // MARK: Internal

    private var whisperKit: WhisperKit?
    private var loadedModel: String?

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

    private static let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "flac", "aac", "ogg", "wma", "aiff", "caf",
        "mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv", "flv",
    ]

    func addFiles(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            if !droppedFileURLs.contains(where: { $0.path == url.path }) {
                droppedFileURLs.append(url)
            }
        }
    }

    func removeFile(at index: Int) {
        guard droppedFileURLs.indices.contains(index) else { return }
        droppedFileURLs.remove(at: index)
    }

    func clearFiles() {
        droppedFileURLs.removeAll()
        transcriptionResult = ""
        status = .idle
    }

    // MARK: Transcription

    func startTranscription() async {
        guard canTranscribe else { return }

        status = .loadingModel
        transcriptionResult = ""

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

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv", "flv",
    ]

    private func prepareAudio(from url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) {
            return try await extractAudio(from: url)
        }
        return url
    }

    private func extractAudio(from videoURL: URL) async throws -> URL {
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
            throw TranscriptionError.audioExtractionFailed
        }

        return outputURL
    }
}
