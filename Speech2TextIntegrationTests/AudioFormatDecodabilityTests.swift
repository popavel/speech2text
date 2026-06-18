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
// all three (verified on macOS 26). The genuinely unsupported formats are wma
// and avi (AVAudioFile/AVURLAsset reject them outright); they're deliberately not
// covered here and are tracked for a separate supported-list trim.

@Suite("Audio format decodability (integration)")
struct AudioFormatDecodabilityTests {

    @Test(
        "Synthesizable audio formats decode through the production AVAudioFile path",
        arguments: ["wav", "aiff", "caf", "m4a", "flac"]
    )
    func synthesizableAudioFormatDecodes(ext: String) throws {
        let url = try MediaFixtures.makeToneAudio(duration: 0.5, ext: ext)
        defer { MediaFixtures.cleanup([url]) }
        try Self.assertDecodable(url)
    }

    @Test(
        "Checked-in fixtures (decodable but not synthesizable) decode through the production path",
        arguments: ["mp3", "aac", "ogg"]
    )
    func bundledFixtureDecodes(ext: String) throws {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: "tone", withExtension: ext),
            "Missing bundled fixture tone.\(ext) — check the Fixtures resources wiring in project.yml"
        )
        try Self.assertDecodable(url)
    }

    @Test(
        "makeToneAudio refuses formats it cannot synthesize",
        arguments: ["mp3", "aac", "ogg", "wma"]
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
