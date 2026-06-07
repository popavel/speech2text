import Foundation
import Testing
@preconcurrency import AVFoundation

@testable import Speech2Text

// Exercises the video → audio stage end-to-end via real AVFoundation. Runs
// unconditionally — hermetic, no network.

@MainActor
@Suite("Audio extraction (integration)")
struct AudioExtractionIntegrationTests {

    @Test("Extracts a usable audio track from a generated MP4")
    func extractsAudioFromMP4() async throws {
        let manager = TranscriptionManager()

        let audio = try MediaFixtures.makeToneAudio(duration: 1.0)
        defer { MediaFixtures.cleanup([audio]) }
        let video = try await MediaFixtures.makeVideoWithAudio(audioURL: audio, ext: "mp4")
        defer { MediaFixtures.cleanup([video]) }

        let extracted = try await manager.extractAudio(from: video)
        defer { MediaFixtures.cleanup([extracted]) }

        try await assertAudioFileIsUsable(extracted, sourceDuration: 1.0)
    }

    @Test("Extracts a usable audio track from a generated MOV")
    func extractsAudioFromMOV() async throws {
        let manager = TranscriptionManager()

        let audio = try MediaFixtures.makeToneAudio(duration: 1.0)
        defer { MediaFixtures.cleanup([audio]) }
        let video = try await MediaFixtures.makeVideoWithAudio(audioURL: audio, ext: "mov")
        defer { MediaFixtures.cleanup([video]) }

        let extracted = try await manager.extractAudio(from: video)
        defer { MediaFixtures.cleanup([extracted]) }

        try await assertAudioFileIsUsable(extracted, sourceDuration: 1.0)
    }

    @Test("Throws noAudioTrack when the video has no audio")
    func noAudioTrackThrows() async throws {
        let manager = TranscriptionManager()
        let video = try await MediaFixtures.makeVideoWithoutAudio(duration: 0.5)
        defer { MediaFixtures.cleanup([video]) }

        await #expect(throws: TranscriptionError.noAudioTrack) {
            _ = try await manager.extractAudio(from: video)
        }
    }

    @Test("prepareAudio returns the same URL for audio inputs")
    func prepareAudioPassesAudioThrough() async throws {
        let manager = TranscriptionManager()
        let audio = try MediaFixtures.makeToneAudio(duration: 0.3, ext: "wav")
        defer { MediaFixtures.cleanup([audio]) }

        let prepared = try await manager.prepareAudio(from: audio)
        #expect(prepared == audio)
    }

    @Test("prepareAudio throws unsupportedFormat for unrecognized extensions")
    func prepareAudioRejectsUnsupportedFormat() async throws {
        let manager = TranscriptionManager()
        let bogus = MediaFixtures.tempURL(ext: "txt")
        try Data("not media".utf8).write(to: bogus)
        defer { MediaFixtures.cleanup([bogus]) }

        await #expect(throws: TranscriptionError.unsupportedFormat("txt")) {
            _ = try await manager.prepareAudio(from: bogus)
        }
    }

    @Test("prepareAudio routes video inputs through extraction")
    func prepareAudioExtractsAudioFromVideo() async throws {
        let manager = TranscriptionManager()
        let audio = try MediaFixtures.makeToneAudio(duration: 0.5)
        defer { MediaFixtures.cleanup([audio]) }
        let video = try await MediaFixtures.makeVideoWithAudio(audioURL: audio, ext: "mp4")
        defer { MediaFixtures.cleanup([video]) }

        let prepared = try await manager.prepareAudio(from: video)
        defer { MediaFixtures.cleanup([prepared]) }

        #expect(prepared != video)
        #expect(prepared.pathExtension == "m4a")
        try await assertAudioFileIsUsable(prepared, sourceDuration: 0.5)
    }

    @Test(
        "makeToneAudio rejects degenerate durations instead of trapping",
        arguments: [0, -1, .infinity, .nan] as [TimeInterval]
    )
    func makeToneAudioRejectsDegenerateDuration(duration: TimeInterval) {
        #expect(throws: MediaFixtureError.self) {
            _ = try MediaFixtures.makeToneAudio(duration: duration)
        }
    }

    // MARK: Helpers

    private func assertAudioFileIsUsable(_ url: URL, sourceDuration: TimeInterval) async throws {
        #expect(FileManager.default.fileExists(atPath: url.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "Extracted audio file is empty")

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty, "Extracted file has no audio track")

        let duration = try await asset.load(.duration).seconds
        // AAC encoding adds small padding; tolerate ±0.5s.
        #expect(abs(duration - sourceDuration) < 0.5,
                "Extracted duration \(duration) far from source \(sourceDuration)")
    }
}
