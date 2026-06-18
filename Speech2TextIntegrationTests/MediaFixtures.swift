import Foundation
@preconcurrency import AVFoundation

// MARK: - Errors

enum MediaFixtureError: Error {
    case synthesizerFailed
    case synthesizerTimedOut
    case noAudioTrack
    case writerFailed
    case readerFailed
    case pixelBufferFailed
    case toneGenerationFailed
    case unsupportedToneFormat
}

// MARK: - MediaFixtures

enum MediaFixtures {

    static func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("s2t-fixture-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    static func cleanup(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Tone audio

    /// Extensions `makeToneAudio` can synthesize in-process via `AVAudioFile`.
    /// mp3/ogg/wma are intentionally excluded — Apple's audio stack has no
    /// encoder for them (verified: `afconvert` to mp3 fails with `fmt?`, and
    /// there is no `.ogg`/`.wma` container writer at all), so a caller needing
    /// those must supply a checked-in fixture instead.
    static let encodableToneExtensions: Set<String> = ["wav", "aiff", "caf", "m4a", "flac"]

    static func makeToneAudio(duration: TimeInterval = 1.5, ext: String = "wav") throws -> URL {
        let url = tempURL(ext: ext)
        guard encodableToneExtensions.contains(ext.lowercased()) else {
            throw MediaFixtureError.unsupportedToneFormat
        }
        let sampleRate = 16000.0
        // Throw rather than trap on a degenerate duration (a force-unwrap on a
        // nil buffer would abort the whole test process). Validate the frame
        // count is finite and in range *before* converting to UInt32 — negative,
        // zero, NaN, infinite, and overflowing values all trap that conversion.
        let rawFrameCount = sampleRate * duration
        guard rawFrameCount.isFinite,
              rawFrameCount >= 1,
              rawFrameCount <= Double(AVAudioFrameCount.max)
        else {
            throw MediaFixtureError.toneGenerationFailed
        }
        let frameCount = AVAudioFrameCount(rawFrameCount)
        guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            throw MediaFixtureError.toneGenerationFailed
        }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else {
            throw MediaFixtureError.toneGenerationFailed
        }
        let frequency: Float = 440
        let twoPi = 2 * Float.pi
        for i in 0..<Int(frameCount) {
            channel[i] = 0.5 * sin(twoPi * frequency * Float(i) / Float(sampleRate))
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: audioSettings(for: ext, sampleRate: sampleRate)
        )
        try file.write(from: buffer)
        return url
    }

    // MARK: Speech audio (via AVSpeechSynthesizer — no network)

    static func makeSpeechAudio(
        text: String = "Hello world. This is a speech to text integration test.",
        ext: String = "wav"
    ) async throws -> URL {
        let url = tempURL(ext: ext)
        let writer = SpeechFileWriter(url: url)
        try await writer.synthesize(text: text)
        return url
    }

    // Expected keywords that `tiny` Whisper can reliably pick up from
    // `makeSpeechAudio`'s default text. Loose match — assertions check that
    // at least one of these appears (case-insensitive) to absorb the tiny
    // model's noisy output.
    static let defaultSpeechKeywords: [String] = ["hello", "world", "test", "speech", "integration"]

    // MARK: Video with audio

    static func makeVideoWithAudio(audioURL: URL, ext: String = "mp4") async throws -> URL {
        let url = tempURL(ext: ext)
        let fileType = videoFileType(for: ext)
        let composer = VideoComposer(outputURL: url, fileType: fileType)
        try await composer.compose(audioURL: audioURL)
        return url
    }

    static func makeVideoWithoutAudio(
        duration: TimeInterval = 1.0,
        ext: String = "mp4"
    ) async throws -> URL {
        let url = tempURL(ext: ext)
        let fileType = videoFileType(for: ext)
        let composer = VideoComposer(outputURL: url, fileType: fileType)
        try await composer.composeSilent(duration: duration)
        return url
    }

    // MARK: Internals

    private static func audioSettings(for ext: String, sampleRate: Double) -> [String: Any] {
        switch ext.lowercased() {
        case "wav", "aiff", "caf":
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
            ]
        case "flac":
            return [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
            ]
        default: // m4a (AAC); makeToneAudio's guard rejects anything else.
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
        }
    }

    private static func videoFileType(for ext: String) -> AVFileType {
        switch ext.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        default: return .mp4
        }
    }
}

// MARK: - Speech writer

private final class SpeechFileWriter: @unchecked Sendable {
    let url: URL
    var audioFile: AVAudioFile?
    let synth = AVSpeechSynthesizer()

    init(url: URL) {
        self.url = url
    }

    func synthesize(text: String, timeout: TimeInterval = 30) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate

            // `resume` can be called from the synthesizer's callback queue and
            // from the timeout below, so guard the one-shot flag with a lock.
            let lock = NSLock()
            nonisolated(unsafe) var resumed = false
            let resume: @Sendable (Error?) -> Void = { error in
                lock.lock()
                if resumed { lock.unlock(); return }
                resumed = true
                lock.unlock()
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }

            // Backstop: if the synthesizer never delivers a terminal empty buffer
            // (e.g. no usable voice on a CI runner), don't hang the suite forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resume(MediaFixtureError.synthesizerTimedOut)
            }

            synth.write(utterance) { [weak self] buffer in
                guard let self else {
                    resume(MediaFixtureError.synthesizerFailed)
                    return
                }
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    resume(MediaFixtureError.synthesizerFailed)
                    return
                }
                // The synthesizer signals completion with an empty buffer. If no
                // audio was ever written (e.g. no usable voice on a CI runner
                // produced only this terminal buffer), fail instead of reporting
                // success — otherwise we'd hand back a URL to a file that doesn't
                // exist and the failure would surface far downstream.
                if pcm.frameLength == 0 {
                    resume(self.audioFile == nil ? MediaFixtureError.synthesizerFailed : nil)
                    return
                }
                do {
                    if self.audioFile == nil {
                        self.audioFile = try AVAudioFile(
                            forWriting: self.url,
                            settings: pcm.format.settings
                        )
                    }
                    try self.audioFile?.write(from: pcm)
                } catch {
                    resume(error)
                }
            }
        }
    }
}

// MARK: - Video composer

private final class VideoComposer: @unchecked Sendable {
    let outputURL: URL
    let fileType: AVFileType

    init(outputURL: URL, fileType: AVFileType) {
        self.outputURL = outputURL
        self.fileType = fileType
    }

    func compose(audioURL: URL) async throws {
        let audioAsset = AVURLAsset(url: audioURL)
        let tracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw MediaFixtureError.noAudioTrack
        }
        let duration = try await audioAsset.load(.duration)
        try await writeFile(audioTrack: audioTrack, audioAsset: audioAsset, duration: duration)
    }

    func composeSilent(duration: TimeInterval) async throws {
        try await writeFile(
            audioTrack: nil,
            audioAsset: nil,
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    private func writeFile(
        audioTrack: AVAssetTrack?,
        audioAsset: AVURLAsset?,
        duration: CMTime
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

        let width = 64
        let height = 64
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(videoInput) else { throw MediaFixtureError.writerFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var readerOutput: AVAssetReaderTrackOutput?
        if let audioTrack, let audioAsset {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 16000.0,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw MediaFixtureError.writerFailed }
            writer.add(input)
            audioInput = input

            let reader = try AVAssetReader(asset: audioAsset)
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 16000.0,
                ]
            )
            guard reader.canAdd(output) else { throw MediaFixtureError.readerFailed }
            reader.add(output)
            guard reader.startReading() else { throw MediaFixtureError.readerFailed }
            audioReader = reader
            readerOutput = output
        }

        guard writer.startWriting() else {
            throw writer.error ?? MediaFixtureError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)

        try await writeBlackFrames(into: videoInput, adaptor: adaptor, duration: duration)

        if let audioInput, let readerOutput {
            await writeAudioSamples(into: audioInput, from: readerOutput)
        }
        // AVAssetReaderTrackOutput holds only a weak ref to its reader; keep
        // `audioReader` alive past the sample pump so it isn't released early.
        withExtendedLifetime(audioReader) {}

        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? MediaFixtureError.writerFailed
        }
    }

    private func writeBlackFrames(
        into input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        duration: CMTime
    ) async throws {
        // Keep fps low. Raising it produces many more frames for multi-second
        // speech videos, which stalls the shared-pixel-buffer pump below and hangs
        // makeVideoWithAudio (the short tone videos in the extraction tests have
        // too few frames to trip it). Honoring sub-second durations more precisely
        // isn't worth that risk for an all-black fixture.
        let fps: Int32 = 2
        let totalFrames = max(2, Int(duration.seconds * Double(fps)))
        let frameDuration = CMTime(value: 1, timescale: fps)

        guard let pool = adaptor.pixelBufferPool else {
            throw MediaFixtureError.pixelBufferFailed
        }
        nonisolated(unsafe) let pixelBuffer = try makeBlackPixelBuffer(pool: pool)

        let queue = DispatchQueue(label: "speech2text.fixture.video")
        // The requestMediaDataWhenReady block is @Sendable but runs serially on
        // `queue`, so capturing these non-Sendable AVFoundation objects is safe.
        nonisolated(unsafe) let input = input
        nonisolated(unsafe) let adaptor = adaptor
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) var frameIdx = 0
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if frameIdx >= totalFrames {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameIdx))
                    adaptor.append(pixelBuffer, withPresentationTime: time)
                    frameIdx += 1
                }
            }
        }
    }

    private func writeAudioSamples(
        into input: AVAssetWriterInput,
        from output: AVAssetReaderTrackOutput
    ) async {
        let queue = DispatchQueue(label: "speech2text.fixture.audio")
        // The requestMediaDataWhenReady block is @Sendable but runs serially on
        // `queue`, so capturing these non-Sendable AVFoundation objects is safe.
        nonisolated(unsafe) let input = input
        nonisolated(unsafe) let output = output
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        input.append(sample)
                    } else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }

    private func makeBlackPixelBuffer(pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let pb = buffer else {
            throw MediaFixtureError.pixelBufferFailed
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let bytes = CVPixelBufferGetBaseAddress(pb)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let height = CVPixelBufferGetHeight(pb)
        memset(bytes, 0, bytesPerRow * height)
        return pb
    }
}
