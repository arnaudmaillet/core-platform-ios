import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import UIKit

/// An exported, upload-ready video plus the metadata the media.v1 upload-ticket
/// flow needs (declared mime/size + a content SHA-256), mirroring
/// `MediaCore.EncodedImage` for video. The file lives in the temp directory;
/// the caller uploads it and may delete it after.
public struct ExportedVideo: Sendable, Equatable {
    public let fileURL: URL
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let durationSeconds: Double
    public let byteSize: UInt64
    public let sha256Hex: String
}

public enum VideoExportError: Error, Equatable {
    case unreadable
    case exportFailed
    case noVideoTrack
}

/// Normalizes a picked video for upload: transcodes to a capped-resolution MP4
/// (H.264 + AAC) via `AVAssetExportSession`, then records dimensions, duration,
/// byte size, and a content hash. The backend transcodes again to an ABR ladder
/// (Phase 3); this pass just bounds the upload size and normalizes the codec.
public struct VideoExporter: Sendable {
    private let preset: String

    /// `AVAssetExportPreset1280x720` by default — a sensible upload cap.
    public init(preset: String = AVAssetExportPreset1280x720) {
        self.preset = preset
    }

    public func export(_ sourceURL: URL) async throws -> ExportedVideo {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideoTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoExportError.exportFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await session.export()
        guard session.status == .completed else {
            throw VideoExportError.exportFailed
        }

        // Natural size, transform-corrected so portrait clips report portrait.
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let corrected = naturalSize.applying(transform)
        let width = Int(abs(corrected.width).rounded())
        let height = Int(abs(corrected.height).rounded())

        let duration = try await AVURLAsset(url: outputURL).load(.duration)

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let byteSize = (attrs[.size] as? UInt64) ?? 0

        return ExportedVideo(
            fileURL: outputURL,
            mimeType: "video/mp4",
            pixelWidth: width,
            pixelHeight: height,
            durationSeconds: duration.seconds.isFinite ? duration.seconds : 0,
            byteSize: byteSize,
            sha256Hex: try Self.sha256Hex(of: outputURL)
        )
    }

    /// A poster frame for the compose preview and the feed thumbnail.
    /// Best-effort; returns nil if generation fails.
    ///
    /// ⚠️ **NOT AT t=0, BECAUSE REAL FILM OPENS ON BLACK.** This asked for
    /// exactly zero, and the doc called it "the first ~clean frame" as though it
    /// were. It is not: a great deal of real content fades in, and the very
    /// first frame is then a black rectangle — which becomes the post's
    /// `thumbnail_url`, and a black thumbnail is indistinguishable from the
    /// no-thumbnail bug this poster exists to prevent.
    ///
    /// Found the moment real encodes were put behind the device-media mock: Big
    /// Buck Bunny's tile drew its forest, and the Sintel trailer's drew pure
    /// black, because Sintel opens on a fade. Both files are perfectly fine.
    ///
    /// A tenth of the way in, capped at one second — far enough past an opening
    /// fade for ordinary content, near enough that the poster is still
    /// recognisably the start of the clip. Zero remains the fallback, so a clip
    /// too short or too stubborn for the offset still gets a picture rather than
    /// nothing.
    public func posterImage(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // ⚠️ **AT OR AFTER, NEVER BEFORE — OR THE OFFSET BUYS NOTHING.** The
        // default tolerance is infinite in BOTH directions, so the generator is
        // free to answer with the nearest keyframe, and on a short clip the
        // nearest keyframe to "a tenth of the way in" is frame zero. The whole
        // point is to be past the opening, so earlier is not an acceptable
        // answer; later is.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let offset = seconds.isFinite && seconds > 0 ? min(1, seconds / 10) : 0
        if offset > 0,
           let frame = await Self.frame(from: generator, atSeconds: offset) {
            return frame
        }
        return await Self.frame(from: generator, atSeconds: 0)
    }

    private static func frame(
        from generator: AVAssetImageGenerator, atSeconds seconds: Double
    ) async -> UIImage? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try? await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                if let cgImage {
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                } else {
                    continuation.resume(throwing: error ?? VideoExportError.unreadable)
                }
            }
        }
    }

    /// Streams the file through SHA-256 so large clips aren't buffered whole.
    private static func sha256Hex(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw VideoExportError.unreadable
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
