import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import UIKit

/// Resolves a post's media URL to a locally-playable URL for `AVPlayerItem`.
/// The player subsystem owns pooling and playback; sources only produce a URL
/// an `AVPlayer` can open — a passthrough remote URL in production, or a
/// synthesized file in mock mode. Mirrors `ImageFetching` for video.
public protocol VideoSource: Sendable {
    func playableURL(for url: URL) async throws -> URL
}

/// Production source: the delivery URL is already playable (progressive MP4 or
/// an HLS manifest), so it passes straight through. This lights up for real
/// once the backend serves video renditions (Phase 3).
public struct PassthroughVideoSource: VideoSource {
    public init() {}
    public func playableURL(for url: URL) async throws -> URL { url }
}

public enum VideoSynthesisError: Error, Equatable {
    case writerUnavailable
    case encodingFailed
}

/// Deterministic offline source for mock mode: synthesizes a short, looping
/// H.264 clip whose hue is derived from the URL (so every post keeps its color,
/// like `PlaceholderImageFetcher`) with a sweeping band so playback is visibly
/// moving. Clips are cached on disk by URL, so re-resolving is free. Keeps the
/// whole player subsystem — pool, preroll, lifecycle, audio — exercised end to
/// end with zero network and no committed binary assets.
public struct PlaceholderVideoFetcher: VideoSource {
    private let durationSeconds: Double
    private let framesPerSecond: Int32

    public init(durationSeconds: Double = 2.5, framesPerSecond: Int32 = 30) {
        self.durationSeconds = durationSeconds
        self.framesPerSecond = framesPerSecond
    }

    public func playableURL(for url: URL) async throws -> URL {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func dim(_ name: String, _ fallback: Int) -> Int {
            components?.queryItems?.first { $0.name == name }.flatMap { Int($0.value ?? "") } ?? fallback
        }
        // Cap and round to even dimensions (H.264 requires even width/height).
        let width = min(max(dim("w", 720), 16), 720) & ~1
        let height = min(max(dim("h", 1280), 16), 1280) & ~1

        var hasher = Hasher()
        hasher.combine(url.path)
        let hue = CGFloat(abs(hasher.finalize() % 360)) / 360

        let cacheURL = Self.cacheURL(for: url, width: width, height: height)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }
        try await synthesize(to: cacheURL, width: width, height: height, hue: hue)
        return cacheURL
    }

    private static func cacheURL(for url: URL, width: Int, height: Int) -> URL {
        var hasher = Hasher()
        hasher.combine(url.absoluteString)
        hasher.combine(width)
        hasher.combine(height)
        let name = "synthvid-\(UInt(bitPattern: hasher.finalize())).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private func synthesize(to outputURL: URL, width: Int, height: Int, hue: CGFloat) async throws {
        // Write to a unique temp file then move into place, so concurrent
        // resolves of the same URL can't corrupt a half-written clip.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthvid-\(UUID().uuidString).mp4")

        guard let writer = try? AVAssetWriter(outputURL: scratch, fileType: .mp4) else {
            throw VideoSynthesisError.writerUnavailable
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { throw VideoSynthesisError.writerUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw VideoSynthesisError.encodingFailed }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(durationSeconds * Double(framesPerSecond))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let buffer = Self.makeFrame(
                width: width, height: height, hue: hue,
                progress: Double(frame) / Double(frameCount)
            ) else {
                writer.cancelWriting()
                throw VideoSynthesisError.encodingFailed
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw VideoSynthesisError.encodingFailed }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: scratch, to: outputURL)
    }

    /// One frame: a solid hue background with a vertical band sweeping across,
    /// so the clip obviously animates and reads well full-screen.
    private static func makeFrame(width: Int, height: Int, hue: CGFloat, progress: Double) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        UIColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // A lighter band sweeping left→right and wrapping.
        let bandWidth = CGFloat(width) * 0.25
        let x = CGFloat(progress) * CGFloat(width) * 1.25 - bandWidth
        UIColor(hue: hue, saturation: 0.35, brightness: 0.95, alpha: 1).setFill()
        context.fill(CGRect(x: x, y: 0, width: bandWidth, height: CGFloat(height)))

        return buffer
    }
}
