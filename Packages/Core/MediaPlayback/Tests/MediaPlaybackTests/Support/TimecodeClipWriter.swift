import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A clip whose picture AND sound each say which moment of the file they are,
/// for the tests that ask whether the two stay together.
///
/// 160x120, six seconds at 30fps, keyed every half second. The PICTURE is black
/// with one lit square: the file is a grid of 8px cells, twenty to a row, and
/// frame `n` lights cell `n` — so a blend of two frames lights two cells, each
/// as bright as its share, and the brighter one is the picture that dominates.
/// The SOUND is a sine whose pitch climbs 400 Hz a second from 300 Hz, so its
/// pitch is its clock: one frame of film is 13.3 Hz.
enum TimecodeClipWriter {
    static let width = 160
    static let height = 120
    static let seconds = 6
    static let cell = 8
    static let cellsPerRow = width / cell
    static let rate: Double = 44_100
    static let startPitch = 300.0
    static let climb = 400.0

    /// Which moment of the file a pitch belongs to.
    static func fileSeconds(forPitch pitch: Double) -> Double {
        (pitch - startPitch) / climb
    }

    /// The centre of frame `n`'s cell, in pixels from the top left.
    static func centre(ofFrame n: Int) -> (x: Int, y: Int) {
        ((n % cellsPerRow) * cell + cell / 2, (n / cellsPerRow) * cell + cell / 2)
    }

    static var frames: Int { seconds * 30 }

    static func clip() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timecode-clip.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // ⚠️ A NAME OF ITS OWN: two suites run side by side and may both write it.
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-timecode-clip.mov")

        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 15,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoAverageBitRateKey: 4_000_000
            ]
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(video)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(audio)

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // ⚠️ INTERLEAVED, WITH THE SOUND HALF A SECOND AHEAD AND FINISHED AS
        // SOON AS IT IS ALL GIVEN. The writer interleaves what it is given and
        // will not run one input far past the other. Six seconds of sound first
        // (`ColourClipWriter`'s order, which its four get away with) left the
        // SOUND input never ready again; sound given as the pictures went but
        // finished only after them left the PICTURE input never ready at frame
        // 169 of 180 — the AAC encoder hands over its last packets only once it
        // is told the sound is finished. Both measured, both a hang on
        // `isReadyForMoreMediaData`, hence `ready`'s deadline.
        let total = Int(rate) * seconds
        var written = 0
        for frame in 0..<frames {
            let soundUntil = min(Int((Double(frame + 1) / 30 + 0.5) * rate), total)
            if soundUntil > written {
                try await ready(audio, of: writer, "sound at frame \(frame)")
                guard audio.append(try chirp(from: written, count: soundUntil - written)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                written = soundUntil
                // ⚠️ FINISHED THE MOMENT IT IS ALL GIVEN — the encoder hands over
                // its last packets only then, and the pictures wait for them.
                if written == total { audio.markAsFinished() }
            }
            try await ready(video, of: writer, "picture at frame \(frame)")
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let pixels = made else { throw CocoaError(.fileWriteUnknown) }
            paint(pixels, frame: frame)
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        video.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        do {
            try FileManager.default.moveItem(at: partial, to: url)
        } catch where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: partial)
        }
        return url
    }

    /// Waits for `input` to take more, and gives up after ten seconds — a
    /// writer that never becomes ready again is a failure, not a hang.
    private static func ready(_ input: AVAssetWriterInput, of writer: AVAssetWriter, _ name: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            guard Date() < deadline else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "the \(name) input never became ready (writer status \(writer.status.rawValue))"
                ])
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func paint(_ pixels: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let lit = centre(ofFrame: frame)
        for y in 0..<height {
            for x in 0..<width {
                let inside = abs(x - lit.x) < cell / 2 - 1 && abs(y - lit.y) < cell / 2 - 1
                let value: UInt8 = inside ? 255 : 0
                let at = y * row + x * 4
                bytes[at] = value
                bytes[at + 1] = value
                bytes[at + 2] = value
                bytes[at + 3] = 255
            }
        }
    }

    /// `count` samples of the climbing sine from sample `start` — its phase
    /// written in closed form, `2π(f₀t + kt²/2)`, so chunks join without a click.
    private static func chirp(from start: Int, count: Int) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        )
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(start + index) / rate
            let phase = 2 * .pi * (startPitch * t + climb * t * t / 2)
            samples[index] = Int16(sin(phase) * 20_000)
        }
        var block: CMBlockBuffer?
        let length = count * 2
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block
        )
        guard let block, let description else { throw CocoaError(.fileWriteUnknown) }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length
            )
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: description,
            sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &buffer
        )
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        return buffer
    }

    // MARK: - Reading back

    /// The two brightest cells of a frame: which frame of the file each is, and
    /// how bright, brightest first.
    static func litCells(in buffer: CVPixelBuffer) -> [(frame: Int, level: Int)] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
        else { return [] }
        var levels: [(frame: Int, level: Int)] = []
        for frame in 0..<frames {
            let at = centre(ofFrame: frame)
            levels.append((frame, Int(base[at.y * row + at.x * 4 + 1])))
        }
        return Array(levels.sorted { $0.level > $1.level }.prefix(2))
    }

    /// The moment of the file the sound is at, `seconds` into `samples` (mono,
    /// 44.1 kHz): its pitch from where it rises through zero — each crossing
    /// placed between two samples by where the line through them meets zero —
    /// over 30ms around the moment.
    static func soundSeconds(in samples: [Int16], at seconds: Double) -> Double? {
        let from = max(Int((seconds - 0.015) * rate), 1)
        let to = min(Int((seconds + 0.015) * rate), samples.count)
        guard to > from + 2 else { return nil }
        var crossings: [Double] = []
        for index in from..<to where samples[index - 1] < 0 && samples[index] >= 0 {
            let before = Double(samples[index - 1])
            let after = Double(samples[index])
            crossings.append(Double(index - 1) + (-before / (after - before)))
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 2 else { return nil }
        let pitch = Double(crossings.count - 1) / ((last - first) / rate)
        return fileSeconds(forPitch: pitch)
    }
}
