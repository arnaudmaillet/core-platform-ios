import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A clip that MOVES, for the tests that ask whether two moments of one shot
/// can be told apart — which `ColourClipWriter`'s flat seconds cannot answer:
/// every frame of its green second is the same frame.
///
/// 160x120, four seconds at 30fps, keyed every half second, silent: black and
/// white stripes 16px wide (a 32px period) running RIGHT at 64px a second — so
/// a quarter of a second moves them half a period and turns every stripe over.
///
/// ⚠️ **STRIPES, NOT A RAMP.** A dissolve of a ramp with two copies of itself
/// shifted either way IS the ramp, everywhere but at its jump — two moments
/// blended would read as one. Two stripe patterns blended are grey wherever
/// they disagree.
enum StripeClipWriter {
    static let width = 160
    static let height = 120
    static let seconds = 4
    static let period = 32
    /// Pixels a second the stripes travel.
    static let speed = 64.0

    /// Whether the stripe pattern is white at column `x`, `seconds` in.
    static func isWhite(x: Double, at seconds: Double) -> Bool {
        let shifted = (x - speed * seconds).truncatingRemainder(dividingBy: Double(period))
        let within = shifted < 0 ? shifted + Double(period) : shifted
        return within < Double(period) / 2
    }

    static func clip() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stripe-clip.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // ⚠️ A NAME OF ITS OWN: two suites run side by side and may both write it.
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-stripe-clip.mov")

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
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let pixels = made else { throw CocoaError(.fileWriteUnknown) }
            paint(pixels, at: Double(frame) / 30)
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

    private static func paint(_ pixels: CVPixelBuffer, at seconds: Double) {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let value: UInt8 = isWhite(x: Double(x) + 0.5, at: seconds) ? 255 : 0
            for y in 0..<height {
                let at = y * row + x * 4
                bytes[at] = value
                bytes[at + 1] = value
                bytes[at + 2] = value
                bytes[at + 3] = 255
            }
        }
    }
}
