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

/// What to make of a picked clip on its way to the upload.
///
/// ⚠️ **A VALUE RATHER THAN MORE PARAMETERS, BECAUSE THIS LIST IS GOING TO
/// GROW.** Trim needs a time range; crop and filters will need a composition,
/// which cannot simply be passed in — `AVComposition` is not `Sendable` and a
/// composition has to be built where its asset lives, so that slot will be a
/// BUILDER. Adding it to a struct changes no call site; adding it to a
/// parameter list changes every one.
///
/// It is not here yet, on purpose: an unused slot is dead code, and this repo
/// has just removed one for exactly that reason.
public struct VideoExportPlan: Sendable {
    public let sourceURL: URL

    /// The part of the clip to keep, in seconds from its start.
    ///
    /// ⚠️ **NIL IS NOT THE SAME AS "0 TO THE DURATION".** Nil leaves
    /// `AVAssetExportSession.timeRange` alone, which is the passthrough every
    /// untrimmed clip has always taken; a range covering the whole clip still
    /// makes the session re-encode it. `MediaTrimming.cuts(_:within:)` is what
    /// the caller asks to tell the two apart.
    public let timeRange: ClosedRange<Double>?

    /// Nil takes the exporter's own preset.
    public let preset: String?

    public init(
        sourceURL: URL, timeRange: ClosedRange<Double>? = nil, preset: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.timeRange = timeRange
        self.preset = preset
    }
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

    /// The whole clip, unchanged — what every caller asked for before a trim
    /// existed, kept so widening the requirement churned nothing.
    public func export(_ sourceURL: URL) async throws -> ExportedVideo {
        try await export(VideoExportPlan(sourceURL: sourceURL))
    }

    public func export(_ plan: VideoExportPlan) async throws -> ExportedVideo {
        let asset = AVURLAsset(url: plan.sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideoTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: plan.preset ?? preset)
        else {
            throw VideoExportError.exportFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        // ⚠️ **ASSIGNED ONLY WHEN THERE IS ONE.** Setting a range that happens
        // to cover the whole clip is not the same as setting none: the session
        // re-encodes either way, and every untrimmed video would start paying
        // for a feature it is not using.
        if let seconds = plan.timeRange {
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: seconds.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: seconds.upperBound, preferredTimescale: 600)
            )
        }

        await session.export()
        guard session.status == .completed else {
            throw VideoExportError.exportFailed
        }

        // Natural size, transform-corrected so portrait clips report portrait.
        // Read from the SOURCE track: a trim changes how long the clip runs, not
        // how big its pictures are. The duration below is read from the OUTPUT
        // for the opposite reason.
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
