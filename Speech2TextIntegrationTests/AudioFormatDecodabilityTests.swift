import Foundation
import Testing
@preconcurrency import AVFoundation

@testable import Speech2Text

// Proves every audio format the app can synthesize at runtime actually decodes
// through the *production* read path, end-to-end and hermetically (no model, no
// network). WhisperKit's `AudioProcessor.loadAudio(fromPath:)` opens files with
// `AVAudioFile(forReading:commonFormat: .pcmFormatFloat32, interleaved: false)`,
// so the oracle below mirrors that exact call: if it yields PCM frames, the app
// can transcribe the format.
//
// This deliberately covers a gap the static `SupportedExtensionsTests` cannot —
// `UTType` conformance says a format *registers* as audio, not that Apple's
// codecs can actually decode it. It also gives `wav` a real decode assertion it
// previously lacked (the existing extraction suite only tests wav *routing*).
//
// mp3/aac/ogg are covered via tiny checked-in fixtures (Fixtures/tone.{mp3,aac,
// ogg}) rather than runtime synthesis: Apple has no mp3 or Ogg encoder, and raw
// ADTS .aac isn't reliably writable via AVAudioFile — yet AVAudioFile *decodes*
// all three (verified on macOS 26). wma and avi were *removed* from the supported
// lists because the app's stack can't decode them (AVAudioFile/AVURLAsset reject
// them outright); `everyAdvertisedAudioFormatDecodes` below now asserts every
// still-advertised format really is decodable, so a regression can't slip back in.

@Suite("Audio format decodability (integration)")
struct AudioFormatDecodabilityTests {

    /// The invariant: every extension the app advertises in
    /// `supportedAudioExtensions` must actually decode through the production
    /// path. Synthesizable formats are generated on the fly; the rest load from
    /// checked-in fixtures. An advertised format with no decodable sample fails
    /// here — which is exactly what flagged wma before it was removed.
    @Test("Every advertised audio format decodes through the production path")
    func everyAdvertisedAudioFormatDecodes() throws {
        for ext in TranscriptionManager.supportedAudioExtensions.sorted() {
            if MediaFixtures.encodableToneExtensions.contains(ext) {
                let url = try MediaFixtures.makeToneAudio(duration: 0.3, ext: ext)
                defer { MediaFixtures.cleanup([url]) }
                try Self.assertDecodable(url)
            } else if let fixture = Bundle(for: BundleToken.self).url(
                forResource: "tone", withExtension: ext
            ) {
                try Self.assertDecodable(fixture)
            } else {
                Issue.record(
                    "Advertised audio format .\(ext) has no decodable sample (not synthesizable, no Fixtures/tone.\(ext)) — it cannot be transcribed"
                )
            }
        }
    }

    @Test(
        "makeToneAudio refuses formats it cannot synthesize",
        arguments: Array(
            TranscriptionManager.supportedAudioExtensions
                .subtracting(MediaFixtures.encodableToneExtensions)
        )
    )
    func makeToneAudioRejectsNonEncodableFormats(ext: String) {
        #expect(throws: MediaFixtureError.unsupportedToneFormat) {
            _ = try MediaFixtures.makeToneAudio(duration: 0.5, ext: ext)
        }
    }

    // MARK: Oracle

    /// Mirrors WhisperKit's `AudioProcessor.loadAudio(fromPath:)`: open with the
    /// float32 common format and read a buffer. Throwing here == the app cannot
    /// decode the file; zero frames == it decoded to silence/empty.
    static func assertDecodable(_ url: URL) throws {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                             frameCapacity: max(1, frameCount)),
            "Could not allocate PCM buffer for \(url.lastPathComponent)"
        )
        try file.read(into: buffer)
        #expect(buffer.frameLength > 0,
                "Decoded zero frames from \(url.lastPathComponent)")
    }
}

/// Class anchor so `Bundle(for:)` can locate the integration-test bundle that
/// carries the checked-in `Fixtures/` resources (Swift Testing suites are
/// structs, which `Bundle(for:)` cannot key off of).
private final class BundleToken {}
