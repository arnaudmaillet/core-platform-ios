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

    /// A poster frame (first ~clean frame) for the compose preview and the
    /// feed thumbnail. Best-effort; returns nil if generation fails.
    public func posterImage(for url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0, preferredTimescale: 600)
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
