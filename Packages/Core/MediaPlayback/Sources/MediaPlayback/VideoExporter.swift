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

    /// The pieces of the clip to keep, in order, each with the rate it plays at.
    ///
    /// ⚠️ **EMPTY IS NOT THE SAME AS "ONE PIECE COVERING EVERYTHING".** Empty
    /// leaves `AVAssetExportSession.timeRange` alone and builds no composition,
    /// which is the path every untouched clip has always taken; one piece
    /// spanning the whole clip still makes the session re-encode it.
    /// `MediaTimelining.cuts(_:withinSource:)` is what the caller asks to tell
    /// the two apart.
    ///
    /// ⚠️ **AND THE EXPORTER PICKS ITS OWN ROUTE FROM THIS, RATHER THAN BEING
    /// TOLD.** One piece at 1x is a `timeRange` and no composition at all; more
    /// than one, or any rate other than 1x, needs an `AVMutableComposition`.
    /// Leaving that choice to the caller is how a second caller gets it wrong.
    public let segments: [VideoExportSegment]

    /// Nil takes the exporter's own preset.
    public let preset: String?

    public init(
        sourceURL: URL, segments: [VideoExportSegment] = [], preset: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.segments = segments
        self.preset = preset
    }

    /// One piece, at the rate it was shot — the shape a trim has.
    public init(sourceURL: URL, timeRange: ClosedRange<Double>?, preset: String? = nil) {
        self.init(
            sourceURL: sourceURL,
            segments: timeRange.map {
                [VideoExportSegment(start: $0.lowerBound, end: $0.upperBound)]
            } ?? [],
            preset: preset
        )
    }
}

/// One piece of the source, and how fast it plays.
public struct VideoExportSegment: Sendable, Equatable {
    /// Seconds from the start of the SOURCE file.
    public let start: Double
    public let end: Double
    /// 1 is as shot. 2 plays it twice as fast, so it lasts half as long.
    public let speed: Double

    public init(start: Double, end: Double, speed: Double = 1) {
        self.start = start
        self.end = end
        self.speed = speed
    }

    var sourceSeconds: Double { max(end - start, 0) }
    var isAsShot: Bool { abs(speed - 1) < 0.001 }
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

    /// Whether a plan can be served by a `timeRange` alone.
    ///
    /// ⚠️ **NAMED, BECAUSE IT CANNOT BE SEEN FROM OUTSIDE.** Whether a
    /// composition was built is invisible in the exported file: one piece at 1x
    /// through a composition produces the same pictures and the same duration as
    /// one piece through a `timeRange`. A test comparing the two outputs
    /// therefore proves nothing — and one did, comparing a plan with ITSELF,
    /// since `init(sourceURL:timeRange:)` is sugar over exactly this segment.
    static func needsComposition(for segments: [VideoExportSegment]) -> Bool {
        segments.count > 1 || segments.contains { !$0.isAsShot }
    }

    /// The kept pieces, laid end to end, each scaled to the rate it plays at.
    ///
    /// ⚠️ **BUILT HERE AND USED ONCE, WHICH IS THE ONLY WAY IT CAN EXIST.**
    /// `AVMutableComposition` and `AVMutableCompositionTrack` are explicitly
    /// `@_nonSendable` — the conformance is *unavailable*, measured with
    /// `-emit-sil` — so one can never be stored in a `Sendable` value or handed
    /// across an isolation boundary. Region isolation does allow what happens
    /// here: a composition made inside one function, never escaping except as the
    /// `AVAsset` an export session reads. That is why `VideoExportPlan` carries
    /// segment VALUES and not a composition.
    ///
    /// ⚠️ **`scaleTimeRange` ON THE COMPOSITION, NEVER ON A TRACK.** The
    /// track-level call scales that track alone, so a sped-up piece keeps its
    /// audio at the original rate and the two drift apart for the rest of the
    /// film. The composition-level one moves every track together. Neither is
    /// deprecated; the asset-level `insertTimeRange` IS, which is why the inserts
    /// below are per-track.
    ///
    /// ⚠️ **AND THE CURSOR IS READ BACK FROM THE COMPOSITION, NOT ACCUMULATED.**
    /// Scaling a piece changes how long it occupies the timeline, so the place
    /// the next piece starts is wherever the composition now ends. Adding up
    /// source durations would lay every later piece over the one before it.
    private static func composition(
        of asset: AVAsset, cut segments: [VideoExportSegment]
    ) async throws -> AVComposition {
        guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideoTrack
        }
        let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoExportError.exportFailed
        }
        // A clip with no sound is ordinary — a screen recording, a muted export —
        // and asking for an audio track it cannot fill would leave an empty one.
        let audioTrack = sourceAudio == nil ? nil : composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        for segment in segments where segment.sourceSeconds > 0 {
            let cursor = composition.duration
            let range = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                end: CMTime(seconds: segment.end, preferredTimescale: 600)
            )
            do {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
                if let audioTrack, let sourceAudio {
                    try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
                }
            } catch {
                throw VideoExportError.exportFailed
            }
            guard !segment.isAsShot, segment.speed > 0 else { continue }
            composition.scaleTimeRange(
                CMTimeRange(start: cursor, duration: range.duration),
                toDuration: CMTime(
                    seconds: segment.sourceSeconds / segment.speed, preferredTimescale: 600
                )
            )
        }
        // ⚠️ THE TRANSFORM TRAVELS WITH THE PICTURES. Without it a clip a phone
        // recorded upright exports on its side — the composition track starts
        // with an identity transform whatever the source carried.
        if let transform = try? await sourceVideo.load(.preferredTransform) {
            videoTrack.preferredTransform = transform
        }
        return composition
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

        // ⚠️ **ONE PIECE AT 1x NEVER BUILDS A COMPOSITION.** A `timeRange` on
        // the session is what a trim has always been, and a composition would be
        // a second reader, a second set of tracks and a second thing to get
        // wrong for a result that is identical. The composition exists for what
        // a `timeRange` CANNOT say: several pieces, or a rate other than as-shot.
        let needsComposition = Self.needsComposition(for: plan.segments)
        let subject: AVAsset = needsComposition
            ? try await Self.composition(of: asset, cut: plan.segments)
            : asset

        guard let session = AVAssetExportSession(
            asset: subject, presetName: plan.preset ?? preset
        ) else {
            throw VideoExportError.exportFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        // ⚠️ **PITCH IS SPECTRAL BY DEFAULT, WHICH IS WHAT A SPEED CHANGE WANTS**
        // — a voice sped up keeps its pitch instead of turning into a chipmunk.
        // Stated rather than left implicit because it is one algorithm for the
        // WHOLE export: a timeline mixing 0.5x and 2x gets one treatment, not one
        // per piece.
        session.audioTimePitchAlgorithm = .spectral
        // ⚠️ **ASSIGNED ONLY WHEN THERE IS ONE, AND NEVER OVER A COMPOSITION.**
        // The composition already holds only the film that is kept; a range on
        // top of it would cut the cut. Setting a range that happens to cover the
        // whole clip is also not the same as setting none — the session re-encodes
        // either way, and every untouched video would pay for a feature it is not
        // using.
        if !needsComposition, let only = plan.segments.first {
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: only.start, preferredTimescale: 600),
                end: CMTime(seconds: only.end, preferredTimescale: 600)
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
