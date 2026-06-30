import Foundation
import Testing
import AVFoundation
import UniformTypeIdentifiers
import WhisperKit

@testable import Speech2Text

// MARK: - TranscriptionLanguage

@Suite("TranscriptionLanguage")
struct TranscriptionLanguageTests {
    @Test("All cases have a non-empty display name")
    func displayNamesAreNonEmpty() {
        for language in TranscriptionLanguage.allCases {
            #expect(!language.displayName.isEmpty)
        }
    }

    @Test("IDs are unique across cases")
    func idsAreUnique() {
        let ids = TranscriptionLanguage.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Auto-detect uses an empty code")
    func autoHasEmptyCode() {
        #expect(TranscriptionLanguage.auto.code == "")
    }

    @Test("Each non-auto entry round-trips to its WhisperKit dictionary entry")
    func nonAutoCasesRoundTripToWhisperKit() {
        for language in TranscriptionLanguage.allCases where language != .auto {
            // displayName is the capitalized key; lowercasing recovers the key, which
            // must map back to exactly this entry's code. This catches a key/value swap
            // or a wrong-capitalization derivation bug — unlike a plain
            // `languageCodes.contains(code)`, which is tautological here (every code is
            // drawn from `languages.values`, and `languageCodes == Set(languages.values)`).
            #expect(Constants.languages[language.displayName.lowercased()] == language.code)
        }
    }

    @Test("Covers WhisperKit's full language set plus auto-detect")
    func coversFullLanguageSet() {
        #expect(TranscriptionLanguage.allCases.count == Constants.languages.count + 1)
    }

    @Test("English resolves to a non-auto entry derived from WhisperKit")
    func englishIsDerivedFromWhisperKit() {
        #expect(TranscriptionLanguage.english != .auto)
        #expect(TranscriptionLanguage.english.displayName == "English")
    }

    @Test("WhisperKit still maps the default language code that the .english fixture derives from")
    func defaultLanguageCodeHasAnEntry() {
        // Names the precondition behind the `.english` fixture's `?? .auto` fallback: if a
        // future WhisperKit drops/renames the default-code mapping, this fails with a clear
        // message instead of surfacing indirectly as "expected English, got Auto-detect".
        #expect(Constants.languages.values.contains(Constants.defaultLanguageCode))
    }

    // MARK: - matching(_:) — the searchable picker's filter predicate

    @Test("An empty query returns the full language list")
    func matchingEmptyQueryReturnsAll() {
        #expect(TranscriptionLanguage.matching("") == TranscriptionLanguage.allCases)
    }

    @Test("Matching is case-insensitive")
    func matchingIsCaseInsensitive() {
        #expect(TranscriptionLanguage.matching("english").contains(.english))
        #expect(TranscriptionLanguage.matching("ENGLISH").contains(.english))
    }

    @Test("Matching is a substring match, not a prefix")
    func matchingIsSubstring() {
        // "ngli" sits in the middle of "English" — a prefix-only filter would miss it.
        #expect(TranscriptionLanguage.matching("ngli").contains(.english))
    }

    @Test("A query that matches nothing returns an empty list")
    func matchingNoneReturnsEmpty() {
        #expect(TranscriptionLanguage.matching("zzzznotalanguage").isEmpty)
    }

    @Test("A whitespace-only or padded query is trimmed before matching")
    func matchingTrimsWhitespace() {
        // A blank query is treated as empty → full list, not filtered down to the lone
        // space-containing name ("Haitian Creole").
        #expect(TranscriptionLanguage.matching("   ") == TranscriptionLanguage.allCases)
        // Leading/trailing padding around a real term still matches.
        #expect(TranscriptionLanguage.matching("  english  ").contains(.english))
    }

    // MARK: - submitSelection(_:) — the Return-key (.onSubmit) target

    @Test("Return on a real query selects the top match")
    func submitSelectionPicksTopMatch() {
        #expect(TranscriptionLanguage.submitSelection(for: "english") == .english)
        // Padding around a real term still resolves to the same match.
        #expect(TranscriptionLanguage.submitSelection(for: "  english  ") == .english)
    }

    @Test("Return on a blank query selects nothing (preserves the current selection)")
    func submitSelectionBlankSelectsNothing() {
        // Crucially NOT .auto: matching("") returns the full list whose first entry is
        // Auto-detect, so a naive `filtered.first` would silently reset the selection.
        #expect(TranscriptionLanguage.submitSelection(for: "") == nil)
        #expect(TranscriptionLanguage.submitSelection(for: "   ") == nil)
    }

    @Test("Return on a no-match query selects nothing")
    func submitSelectionNoMatchSelectsNothing() {
        #expect(TranscriptionLanguage.submitSelection(for: "zzzznotalanguage") == nil)
    }
}

// MARK: - WhisperModel

@Suite("WhisperModel")
struct WhisperModelTests {
    @Test("All cases have a non-empty display name")
    func displayNamesAreNonEmpty() {
        for model in WhisperModel.allCases {
            #expect(!model.displayName.isEmpty)
        }
    }

    @Test("Raw values use the openai_whisper- prefix")
    func rawValuesUsePrefix() {
        for model in WhisperModel.allCases {
            #expect(model.rawValue.hasPrefix("openai_whisper-"))
        }
    }

    @Test("Offers the expected curated model set")
    func offersExpectedModels() {
        let raws = Set(WhisperModel.allCases.map(\.rawValue))
        #expect(WhisperModel.allCases.count == 5)
        #expect(raws.contains("openai_whisper-tiny"))
        #expect(raws.contains("openai_whisper-base"))
        #expect(raws.contains("openai_whisper-small"))
        #expect(raws.contains("openai_whisper-large-v3_turbo"))
        #expect(raws.contains("openai_whisper-large-v3"))
    }

    /// Drift guard: every curated raw value must be a real WhisperKit model name.
    /// `WhisperKit(model:)` passes `rawValue` straight to `download(variant:)`, which
    /// resolves it against the repo — a typo (e.g. `-turbo` vs `_turbo`) only surfaces at
    /// download time, as a runtime error. `Constants.knownModels` is WhisperKit's offline,
    /// device-independent model list, so this catches such drift on every CI build with no
    /// network call.
    @Test("Every model raw value is a known WhisperKit model")
    func rawValuesAreKnownToWhisperKit() {
        for model in WhisperModel.allCases {
            #expect(
                Constants.knownModels.contains(model.rawValue),
                "\(model.rawValue) is not in WhisperKit's known models"
            )
        }
    }
}

// MARK: - TranscriptionStatus

@Suite("TranscriptionStatus")
struct TranscriptionStatusTests {
    @Test("idle equals idle")
    func idleEquality() {
        #expect(TranscriptionStatus.idle == .idle)
    }

    @Test("transcribing equality is driven by progress")
    func transcribingEquality() {
        #expect(TranscriptionStatus.transcribing(progress: 0.5) == .transcribing(progress: 0.5))
        #expect(TranscriptionStatus.transcribing(progress: 0.5) != .transcribing(progress: 0.6))
    }

    @Test("error equality is driven by message")
    func errorEquality() {
        #expect(TranscriptionStatus.error("oops") == .error("oops"))
        #expect(TranscriptionStatus.error("oops") != .error("other"))
    }
}

// MARK: - TranscriptionError

@Suite("TranscriptionError")
struct TranscriptionErrorTests {
    @Test("Each case provides a localized description")
    func descriptionsAreProvided() {
        #expect(TranscriptionError.noAudioTrack.errorDescription?.isEmpty == false)
        #expect(TranscriptionError.audioExtractionFailed.errorDescription?.isEmpty == false)
    }

    @Test("unsupportedFormat names the extension, or says there is none")
    func unsupportedFormatDescribesExtension() {
        #expect(
            TranscriptionError.unsupportedFormat("txt").errorDescription
                == "Unsupported file format: .txt"
        )
        #expect(
            TranscriptionError.unsupportedFormat("").errorDescription
                == "Unsupported file format: file has no extension"
        )
    }
}

// MARK: - TranscriptionManager

@MainActor
@Suite("TranscriptionManager")
struct TranscriptionManagerTests {

    // MARK: addFiles

    @Test("Adds supported audio and video files")
    func addsSupportedFiles() {
        let manager = TranscriptionManager()
        let urls = [
            URL(fileURLWithPath: "/tmp/clip.mp3"),
            URL(fileURLWithPath: "/tmp/movie.mp4"),
            URL(fileURLWithPath: "/tmp/voice.wav"),
        ]
        manager.addFiles(urls)
        #expect(manager.droppedFileURLs == urls)
    }

    @Test("Filters out unsupported extensions")
    func filtersUnsupportedExtensions() {
        let manager = TranscriptionManager()
        manager.addFiles([
            URL(fileURLWithPath: "/tmp/notes.txt"),
            URL(fileURLWithPath: "/tmp/photo.jpg"),
            URL(fileURLWithPath: "/tmp/clip.mp3"),
        ])
        #expect(manager.droppedFileURLs.map(\.lastPathComponent) == ["clip.mp3"])
    }

    @Test("Reports skipped files via a warning naming them, without erroring")
    func skippedFilesSurfaceWarning() {
        let manager = TranscriptionManager()
        manager.addFiles([
            URL(fileURLWithPath: "/tmp/notes.txt"),
            URL(fileURLWithPath: "/tmp/photo.jpg"),
            URL(fileURLWithPath: "/tmp/clip.mp3"),
        ])
        // The supported file is still added...
        #expect(manager.droppedFileURLs.map(\.lastPathComponent) == ["clip.mp3"])
        // ...and a partial drop is a non-blocking notice, not a hard error.
        #expect(manager.status == .idle)
        let skipped = manager.skippedFileNames
        #expect(skipped.contains("notes.txt"))
        #expect(skipped.contains("photo.jpg"))
        #expect(!skipped.contains("clip.mp3"))
    }

    @Test("addFiles with only supported files leaves status idle and names nothing skipped")
    func supportedFilesLeaveStatusIdle() {
        let manager = TranscriptionManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/clip.mp3")])
        #expect(manager.status == .idle)
        #expect(manager.skippedFileNames.isEmpty)
    }

    @Test("addFiles with only supported files clears a prior skip notice")
    func supportedFilesClearPriorSkipWarning() {
        let manager = TranscriptionManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(!manager.skippedFileNames.isEmpty)
        manager.addFiles([URL(fileURLWithPath: "/tmp/clip.mp3")])
        #expect(manager.skippedFileNames.isEmpty)
    }

    @Test("addFiles never overwrites an in-progress transcription status")
    func addFilesKeepsInProgressStatus() {
        let manager = TranscriptionManager()
        manager.status = .transcribing(progress: 0.5)
        // An unsupported drop arriving mid-transcription must not clobber status.
        manager.addFiles([URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(manager.status == .transcribing(progress: 0.5))
        #expect(!manager.skippedFileNames.isEmpty)
    }

    // MARK: deleteAllModels

    @Test("deleteAllModels refuses while a transcription is in progress")
    func deleteAllModelsRefusesWhileProcessing() async {
        let manager = TranscriptionManager()
        manager.status = .transcribing(progress: 0.5)
        // The guard returns before any filesystem work, so this stays hermetic — it
        // never touches the real cache directory.
        let reclaimed = await manager.deleteAllModels()
        #expect(reclaimed == 0)
        #expect(manager.status == .transcribing(progress: 0.5))
    }

    @Test("Cannot start transcription while a model deletion is in progress")
    func cannotTranscribeWhileDeletingModels() {
        let manager = TranscriptionManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/clip.mp3")])
        manager.status = .deletingModels
        // The deletion busy-state must gate the main window's Transcribe button so a
        // transcription can't start mid-delete and race the cache removal.
        #expect(!manager.canTranscribe)
    }

    @Test("startTranscription is a no-op while a model deletion is in progress")
    func startTranscriptionIsNoOpWhileDeletingModels() async {
        let manager = TranscriptionManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/clip.mp3")])
        manager.status = .deletingModels
        // Guard returns before any WhisperKit/network work, so this stays hermetic.
        await manager.startTranscription()
        #expect(manager.status == .deletingModels)
    }

    @Test("deleteAllModels refuses while another deletion is already in progress")
    func deleteAllModelsRefusesWhileAlreadyDeleting() async {
        let manager = TranscriptionManager()
        manager.status = .deletingModels
        // Re-entrancy guard: returns before any filesystem work, so this stays hermetic.
        let reclaimed = await manager.deleteAllModels()
        #expect(reclaimed == 0)
        #expect(manager.status == .deletingModels)
    }

    @Test("Treats extensions case-insensitively")
    func extensionsAreCaseInsensitive() {
        let manager = TranscriptionManager()
        manager.addFiles([
            URL(fileURLWithPath: "/tmp/CLIP.MP3"),
            URL(fileURLWithPath: "/tmp/Movie.MOV"),
        ])
        #expect(manager.droppedFileURLs.count == 2)
    }

    @Test("Does not add the same file twice")
    func deduplicatesByPath() {
        let manager = TranscriptionManager()
        let url = URL(fileURLWithPath: "/tmp/clip.mp3")
        manager.addFiles([url])
        manager.addFiles([url])
        #expect(manager.droppedFileURLs == [url])
    }

    // MARK: removeFile

    @Test("Removes a file at a valid index")
    func removesFileAtIndex() {
        let manager = TranscriptionManager()
        manager.addFiles([
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ])
        manager.removeFile(at: 0)
        #expect(manager.droppedFileURLs.map(\.lastPathComponent) == ["b.mp3"])
    }

    @Test("Ignores out-of-range indices")
    func ignoresOutOfRangeIndex() {
        let manager = TranscriptionManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/a.mp3")])
        manager.removeFile(at: 5)
        manager.removeFile(at: -1)
        #expect(manager.droppedFileURLs.count == 1)
    }

    @Test("Removing a file keeps the skip notice while the queue is non-empty")
    func removeKeepsSkipNoticeUntilQueueEmpty() {
        let manager = TranscriptionManager()
        manager.addFiles([
            URL(fileURLWithPath: "/tmp/notes.txt"),
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ])
        #expect(!manager.skippedFileNames.isEmpty)

        // One of two queued files removed — notice still has a referent.
        manager.removeFile(at: 0)
        #expect(!manager.skippedFileNames.isEmpty)

        // Removing the last file empties the queue — drop the orphaned notice.
        manager.removeFile(at: 0)
        #expect(manager.droppedFileURLs.isEmpty)
        #expect(manager.skippedFileNames.isEmpty)
    }

    // MARK: clearFiles

    @Test("Clears files, result, and resets status")
    func clearFilesResetsState() {
        let manager = TranscriptionManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/a.mp3")])
        manager.transcriptionResult = "hello"
        manager.status = .completed
        manager.clearFiles()
        #expect(manager.droppedFileURLs.isEmpty)
        #expect(manager.transcriptionResult.isEmpty)
        #expect(manager.status == .idle)
    }

    // MARK: isProcessing / canTranscribe

    @Test("isProcessing reflects loading and transcribing states")
    func isProcessingReflectsStatus() {
        let manager = TranscriptionManager()

        manager.status = .idle
        #expect(!manager.isProcessing)

        manager.status = .loadingModel
        #expect(manager.isProcessing)

        manager.status = .transcribing(progress: 0.1)
        #expect(manager.isProcessing)

        manager.status = .completed
        #expect(!manager.isProcessing)

        manager.status = .error("nope")
        #expect(!manager.isProcessing)
    }

    @Test("canTranscribe requires files and an idle pipeline")
    func canTranscribeRequiresFilesAndIdle() {
        let manager = TranscriptionManager()
        #expect(!manager.canTranscribe)

        manager.addFiles([URL(fileURLWithPath: "/tmp/a.mp3")])
        #expect(manager.canTranscribe)

        manager.status = .loadingModel
        #expect(!manager.canTranscribe)
    }

    // MARK: statusMessage

    @Test("statusMessage formats each status")
    func statusMessageFormatting() {
        let manager = TranscriptionManager()

        manager.status = .idle
        #expect(manager.statusMessage.isEmpty)

        manager.status = .loadingModel
        #expect(manager.statusMessage.contains("model"))

        manager.status = .transcribing(progress: 0)
        #expect(manager.statusMessage == "Transcribing...")

        manager.status = .transcribing(progress: 0.42)
        #expect(manager.statusMessage == "Transcribing... 42%")

        manager.status = .completed
        #expect(manager.statusMessage == "Transcription complete")

        manager.status = .error("boom")
        #expect(manager.statusMessage == "Error: boom")
    }

    // MARK: UI-test launch seam

    #if DEBUG
    @Test("Launch seam ignores an empty stub result instead of marking completion")
    func emptyStubResultDoesNotCompleteRun() {
        let manager = TranscriptionManager()
        manager.applyUITestSeamIfPresent(
            arguments: ["-uiTesting"],
            environment: ["UITEST_STUB_RESULT": ""]
        )
        #expect(manager.status == .idle)
        #expect(manager.transcriptionResult.isEmpty)
    }

    @Test("Launch seam applies a non-empty stub result")
    func nonEmptyStubResultCompletesRun() {
        let manager = TranscriptionManager()
        manager.applyUITestSeamIfPresent(
            arguments: ["-uiTesting"],
            environment: ["UITEST_STUB_RESULT": "hello world"]
        )
        #expect(manager.status == .completed)
        #expect(manager.transcriptionResult == "hello world")
    }

    @Test("Launch seam preloads files from the environment variable")
    func preloadFilesSeatsThemInTheQueue() {
        let manager = TranscriptionManager()
        manager.applyUITestSeamIfPresent(
            arguments: ["-uiTesting"],
            environment: ["UITEST_PRELOAD_FILES": "/tmp/a.mp3\n/tmp/b.wav"]
        )
        #expect(manager.droppedFileURLs.count == 2)
        #expect(manager.status == .idle)
    }

    @Test("Stubbed completion clears skippedFileNames even with a mixed preload")
    func stubResultClearsSkippedFileNames() {
        let manager = TranscriptionManager()
        manager.applyUITestSeamIfPresent(
            arguments: ["-uiTesting"],
            environment: [
                "UITEST_PRELOAD_FILES": "/tmp/a.mp3\n/tmp/notes.pdf",
                "UITEST_STUB_RESULT": "hello world",
            ]
        )
        #expect(manager.status == .completed)
        // The stub jumps straight to .completed; it must mirror startTranscription()'s
        // invariant of clearing skippedFileNames, so a mixed preload can't leave the
        // result UI rendered alongside a stale warning row.
        #expect(manager.skippedFileNames.isEmpty)
    }
    #endif
}

// MARK: - Supported Extensions Validation

@Suite("Supported Extensions")
struct SupportedExtensionsTests {

    @Test("App's audio extensions can be decoded by CoreAudio")
    func audioExtensionsAreDecodable() throws {
        for ext in TranscriptionManager.supportedAudioExtensions {
            let utType = try #require(
                UTType(filenameExtension: ext),
                "No UTType found for audio extension '\(ext)'"
            )
            // CoreAudio can decode anything that conforms to public.audio
            #expect(
                utType.conforms(to: .audio),
                "Extension '\(ext)' does not conform to public.audio — CoreAudio/WhisperKit cannot decode it"
            )
        }
    }

    @Test("App's video extensions can be opened by AVAssetExportSession")
    func videoExtensionsAreExportable() throws {
        let exportPresets = AVAssetExportSession.allExportPresets()
        #expect(
            exportPresets.contains(AVAssetExportPresetAppleM4A),
            "AVAssetExportPresetAppleM4A is not available on this system"
        )

        for ext in TranscriptionManager.supportedVideoExtensions {
            let utType = try #require(
                UTType(filenameExtension: ext),
                "No UTType found for video extension '\(ext)'"
            )
            // The app uses AVURLAsset to read these, so they must be audiovisual types
            let avTypes = AVURLAsset.audiovisualTypes()
            let isReadable = avTypes.contains { fileType in
                guard let avUTType = UTType(fileType.rawValue) else { return false }
                return utType.conforms(to: avUTType) || avUTType.conforms(to: utType)
            }
            #expect(
                isReadable,
                "Extension '\(ext)' cannot be read by AVURLAsset — extractAudio(from:) will fail"
            )
        }
    }

    @Test("Audio and video sets don't overlap")
    func noOverlapBetweenSets() {
        let overlap = TranscriptionManager.supportedAudioExtensions
            .intersection(TranscriptionManager.supportedVideoExtensions)
        #expect(overlap.isEmpty, "Extensions in both sets: \(overlap) — ambiguous code path")
    }

    @Test("addFiles accepts exactly the union of audio and video extensions")
    @MainActor
    func addFilesMatchesDeclaredExtensions() {
        let manager = TranscriptionManager()
        let allExtensions = TranscriptionManager.supportedAudioExtensions
            .union(TranscriptionManager.supportedVideoExtensions)

        for ext in allExtensions {
            manager.addFiles([URL(fileURLWithPath: "/tmp/test.\(ext)")])
        }
        #expect(manager.droppedFileURLs.count == allExtensions.count)

        // Verify a bogus extension is rejected
        let before = manager.droppedFileURLs.count
        manager.addFiles([URL(fileURLWithPath: "/tmp/test.xyz")])
        #expect(manager.droppedFileURLs.count == before)
    }
}

// MARK: - Model Cache Storage

/// Exercises the `nonisolated static` cache-size/delete helpers that back the
/// Settings → Storage cleanup. They take a `URL`, so every test runs against an
/// isolated temp directory — no model download, no touching the real
/// `~/Library/Application Support`, no network.
@Suite("Model cache storage")
struct ModelCacheStorageTests {

    /// A fresh, empty temp directory unique to one test. Caller is responsible for
    /// removing it (tests use `defer`).
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write `byteCount` bytes of non-zero data (avoids any sparse-file optimization
    /// that could make an all-zero file report less allocated space than written).
    private func write(_ byteCount: Int, to url: URL) {
        try? Data(repeating: 0xAB, count: byteCount).write(to: url)
    }

    @Test("cacheSize sums regular files recursively, including nested subdirectories")
    func cacheSizeSumsFilesRecursively() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        write(5_000, to: dir.appendingPathComponent("a.bin"))
        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        write(5_000, to: nested.appendingPathComponent("b.bin"))

        // Allocated size rounds up to the filesystem block, so assert a lower bound
        // (>= the bytes written) rather than an exact figure.
        #expect(TranscriptionManager.cacheSize(of: dir) >= 10_000)
    }

    @Test("cacheSize grows when more data is present")
    func cacheSizeIsMonotonic() {
        let small = makeTempDir(); defer { try? FileManager.default.removeItem(at: small) }
        let large = makeTempDir(); defer { try? FileManager.default.removeItem(at: large) }
        write(4_000, to: small.appendingPathComponent("one.bin"))
        write(4_000, to: large.appendingPathComponent("one.bin"))
        write(4_000, to: large.appendingPathComponent("two.bin"))
        #expect(TranscriptionManager.cacheSize(of: large) > TranscriptionManager.cacheSize(of: small))
    }

    @Test("cacheSize of a nonexistent directory is zero")
    func cacheSizeMissingIsZero() {
        let ghost = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(TranscriptionManager.cacheSize(of: ghost) == 0)
    }

    @Test("cacheSize bails out early when its task is cancelled")
    func cacheSizeRespectsCancellation() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        write(50_000, to: dir.appendingPathComponent("a.bin"))

        // A superseded refresh cancels its task; the walk must observe that and abort
        // (rather than completing and wasting the I/O). `Task.yield()` suspends the task
        // so the synchronous `cancel()` below is guaranteed to land before the walk runs.
        let task = Task<Int64, Never> {
            await Task.yield()
            return TranscriptionManager.cacheSize(of: dir)
        }
        task.cancel()
        #expect(await task.value == 0)
    }

    @Test("deleteCache removes the directory and reports the bytes reclaimed")
    func deleteRemovesAndReports() {
        let dir = makeTempDir()
        write(6_000, to: dir.appendingPathComponent("model.bin"))
        let reclaimed = TranscriptionManager.deleteCache(at: dir)
        #expect(reclaimed >= 6_000)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("deleteCache on a missing directory reclaims zero and does not throw")
    func deleteMissingIsZero() {
        let ghost = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(TranscriptionManager.deleteCache(at: ghost) == 0)
        #expect(!FileManager.default.fileExists(atPath: ghost.path))
    }

    @Test("modelCacheDirectory lives under Application Support, namespaced to the bundle id")
    func modelCacheDirectoryLocation() {
        let path = TranscriptionManager.modelCacheDirectory.path
        #expect(path.contains("Application Support"))
        #expect(path.contains("com.speech2text.app"))
        #expect(path.hasSuffix("models"))
    }
}
