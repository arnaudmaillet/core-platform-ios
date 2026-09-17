import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A clip whose every frame is known, for the tests that read pixels.
///
/// 160x120 stored, four seconds at 30fps: RED for the first second, then GREEN,
/// BLUE and WHITE. A CYAN square covers the middle half of every frame, and a
/// YELLOW band 16px deep runs along the top of the UPRIGHT picture — so a
/// rotated variant, stored on its side, shows whether a render turned it.
/// A 440Hz tone plays for the first two seconds, then silence.
///
/// A rotated variant normally carries the shift a phone writes, which brings the
/// turned picture back to the origin; `shifted: false` leaves it out, as some
/// files do. `picture: false` writes the tone alone — a file no arrangement
/// can be built from.
enum ColourClipWriter {
    struct RGB: Equatable, CustomStringConvertible {
        let r: Int
        let g: Int
        let b: Int

        static let red = RGB(r: 255, g: 0, b: 0)
        static let green = RGB(r: 0, g: 255, b: 0)
        static let blue = RGB(r: 0, g: 0, b: 255)
        static let white = RGB(r: 255, g: 255, b: 255)
        static let cyan = RGB(r: 0, g: 255, b: 255)
        static let yellow = RGB(r: 255, g: 255, b: 0)

        var description: String { "(\(r),\(g),\(b))" }

        func near(_ other: RGB, by slack: Int = 48) -> Bool {
            abs(r - other.r) <= slack && abs(g - other.g) <= slack && abs(b - other.b) <= slack
        }
    }

    static let width = 160
    static let height = 120
    static let seconds = 4
    static let band = 16
    static let colours: [RGB] = [.red, .green, .blue, .white]

    /// The clip, written once per variant and reused.
    static func clip(
        rotated: Bool = false, shifted: Bool = true, sound: Bool = true, picture: Bool = true
    ) async throws -> URL {
        let turn = !picture ? "blind" : rotated ? (shifted ? "turned" : "turned-unshifted") : "flat"
        let name = "colour-clip-\(turn)-\(sound ? "sound" : "silent").mov"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // ⚠️ A NAME OF ITS OWN: two suites run side by side and may both write it.
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")

        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 15,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoAverageBitRateKey: 2_000_000
            ]
        ])
        video.expectsMediaDataInRealTime = false
        if rotated {
            // As a phone held upright records: landscape pixels, turned a
            // quarter clockwise by the track's transform.
            video.transform = CGAffineTransform(
                a: 0, b: 1, c: -1, d: 0, tx: shifted ? CGFloat(height) : 0, ty: 0
            )
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        if picture { writer.add(video) }

        let rate = 44_100.0
        let audio: AVAssetWriterInput? = sound ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]) : nil
        if let audio {
            audio.expectsMediaDataInRealTime = false
            writer.add(audio)
        }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // ⚠️ THE SOUND IS WRITTEN AND FINISHED FIRST: a writer waits for every
        // input it holds, and one left open hangs `finishWriting` for good.
        if let audio {
            let total = Int(rate) * seconds
            let chunk = 4_410
            var written = 0
            while written < total {
                while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                let count = min(chunk, total - written)
                let buffer = try toneBuffer(from: written, count: count, rate: rate)
                guard audio.append(buffer) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                written += count
            }
            audio.markAsFinished()
        }

        for frame in 0..<(picture ? seconds * 30 : 0) {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let pixels = made else { throw CocoaError(.fileWriteUnknown) }
            paint(pixels, colour: colours[min(frame / 30, colours.count - 1)], rotated: rotated)
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        if picture { video.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        do {
            try FileManager.default.moveItem(at: partial, to: url)
        } catch where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: partial)
        }
        return url
    }

    private static func paint(_ pixels: CVPixelBuffer, colour: RGB, rotated: Bool) {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                // The upright picture's top is the stored LEFT edge when turned.
                let inBand = rotated ? x < band : y < band
                let inSquare = x >= width / 4 && x < width * 3 / 4 && y >= height / 4 && y < height * 3 / 4
                let paint = inBand ? RGB.yellow : inSquare ? RGB.cyan : colour
                let at = y * row + x * 4
                bytes[at] = UInt8(paint.b)
                bytes[at + 1] = UInt8(paint.g)
                bytes[at + 2] = UInt8(paint.r)
                bytes[at + 3] = 255
            }
        }
    }

    private static func toneBuffer(from start: Int, count: Int, rate: Double) throws -> CMSampleBuffer {
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
            let at = start + index
            guard Double(at) < rate * 2 else { continue }
            samples[index] = Int16(sin(2 * .pi * 440 * Double(at) / rate) * 20_000)
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

    /// One pixel of `asset` at `seconds`, drawn through `composition`, at a
    /// point given as fractions of the rendered picture (0,0 top left), with
    /// the time the generator actually used.
    static func pixel(
        of asset: AVAsset, composition: AVVideoComposition?, at seconds: Double,
        x: Double = 0.5, y: Double = 0.5, upright: Bool = true
    ) async throws -> (colour: RGB, actual: Double, size: CGSize) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.appliesPreferredTrackTransform = upright
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, actual) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        var buffer = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let column = CGFloat(Int(Double(image.width) * x))
        // CoreGraphics counts rows from the bottom.
        let row = CGFloat(Int(Double(image.height) * (1 - y)))
        context.draw(
            image, in: CGRect(x: -column, y: -row, width: CGFloat(image.width), height: CGFloat(image.height))
        )
        return (
            RGB(r: Int(buffer[0]), g: Int(buffer[1]), b: Int(buffer[2])),
            actual.seconds,
            CGSize(width: image.width, height: image.height)
        )
    }
}
