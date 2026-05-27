import Foundation
@preconcurrency import AVFoundation

// MARK: - Errors

enum MediaFixtureError: Error {
    case synthesizerFailed
    case noAudioTrack
    case writerFailed
    case readerFailed
    case pixelBufferFailed
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

    static func makeToneAudio(duration: TimeInterval = 1.5, ext: String = "wav") throws -> URL {
        let url = tempURL(ext: ext)
        let sampleRate = 16000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
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
        let fileType: AVFileType = (ext.lowercased() == "mov") ? .mov : .mp4
        let composer = VideoComposer(outputURL: url, fileType: fileType)
        try await composer.compose(audioURL: audioURL)
        return url
    }

    static func makeVideoWithoutAudio(
        duration: TimeInterval = 1.0,
        ext: String = "mp4"
    ) async throws -> URL {
        let url = tempURL(ext: ext)
        let fileType: AVFileType = (ext.lowercased() == "mov") ? .mov : .mp4
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
        default:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
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

    func synthesize(text: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate

            var resumed = false
            let resume: (Error?) -> Void = { error in
                guard !resumed else { return }
                resumed = true
                if let error { cont.resume(throwing: error) } else { cont.resume() }
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
                // The synthesizer signals completion with an empty buffer.
                if pcm.frameLength == 0 {
                    resume(nil)
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
