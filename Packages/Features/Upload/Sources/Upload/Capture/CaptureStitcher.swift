@preconcurrency import AVFoundation
import Foundation

/// Joins a take's clips into ONE movie file, in the order they were recorded.
///
/// ⚠️ **ONE VIDEO, BECAUSE THE EDITOR EDITS ONE.** The author recorded several
/// clips towards a single video; handed over as several items they would become
/// several pages of a carousel post, which is not what was shot. Stitched, they
/// arrive as one clip whose timeline the editor can cut and re-order as usual.
///
/// ⚠️ **PASSTHROUGH WHEN THE CLIPS AGREE, RE-ENCODED ONLY WHEN THEY DO NOT.**
/// Clips from one camera share a size and a track transform, and are copied
/// sample for sample — no quality lost, and a three-minute take is joined in
/// the time it takes to write the file. A take that flipped cameras mid-way can
/// mix sizes and transforms, which a single composition track cannot carry: it
/// is then drawn through a video composition that turns each clip upright and
/// fits it to the first one's frame.
///
/// ⚠️ **AVCOMPOSITION IS NOT `Sendable`** (`upload-video-publishes` measured it
/// with `-emit-sil`), so it is built and exported inside one nonisolated
/// function and never crosses an isolation boundary; only URLs travel.
enum CaptureStitcher {
    enum Failure: Error, Equatable {
        case noClips
        case unreadable
        case exportFailed
    }

    /// A single clip is handed back as it is — there is nothing to join.
    static func stitch(_ clips: [URL], to output: URL) async throws -> URL {
        guard let first = clips.first else { throw Failure.noClips }
        guard clips.count > 1 else { return first }

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.unreadable }
        var audio: AVMutableCompositionTrack?

        struct Placed {
            let range: CMTimeRange
            let natural: CGSize
            let transform: CGAffineTransform
        }
        var placed: [Placed] = []
        var cursor = CMTime.zero
        for url in clips {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = try await asset.load(.duration)
            let (natural, transform, trackRange) = try await track.load(.naturalSize, .preferredTransform, .timeRange)
            // The video track's own range, never past the asset: a clip whose
            // audio runs a frame longer would otherwise leave a black frame.
            let range = CMTimeRange(start: trackRange.start, duration: CMTimeMinimum(trackRange.duration, duration))
            try video.insertTimeRange(range, of: track, at: cursor)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                if audio == nil {
                    audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                let soundRange = CMTimeRange(start: range.start, duration: range.duration)
                try? audio?.insertTimeRange(soundRange, of: sound, at: cursor)
            }
            placed.append(Placed(range: CMTimeRange(start: cursor, duration: range.duration), natural: natural, transform: transform))
            cursor = cursor + range.duration
        }
        guard let lead = placed.first else { throw Failure.unreadable }

        let uniform = placed.allSatisfy { $0.natural == lead.natural && $0.transform == lead.transform }
        let session: AVAssetExportSession?
        if uniform {
            video.preferredTransform = lead.transform
            session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        } else {
            session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
            session?.videoComposition = Self.uprightComposition(for: placed.map { ($0.range, $0.natural, $0.transform) }, track: video)
        }
        guard let session else { throw Failure.exportFailed }
        try? FileManager.default.removeItem(at: output)
        do {
            try await session.export(to: output, as: .mov)
        } catch {
            throw Failure.exportFailed
        }
        return output
    }

    /// Each clip turned upright and fitted, centred, into the first clip's
    /// upright frame.
    private static func uprightComposition(
        for pieces: [(CMTimeRange, CGSize, CGAffineTransform)], track: AVCompositionTrack
    ) -> AVVideoComposition {
        func upright(_ natural: CGSize, _ transform: CGAffineTransform) -> CGSize {
            let box = CGRect(origin: .zero, size: natural).applying(transform)
            return CGSize(width: abs(box.width), height: abs(box.height))
        }
        let render = upright(pieces[0].1, pieces[0].2)
        var configuration = AVVideoComposition.Configuration()
        configuration.renderSize = CGSize(width: (render.width / 2).rounded() * 2, height: (render.height / 2).rounded() * 2)
        configuration.frameDuration = CMTime(value: 1, timescale: 30)
        configuration.instructions = pieces.map { range, natural, transform in
            let size = upright(natural, transform)
            // The track transform can leave the picture off the origin; move it
            // back before scaling it into the frame.
            let box = CGRect(origin: .zero, size: natural).applying(transform)
            let scale = min(render.width / size.width, render.height / size.height)
            let fitted = transform
                .concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(
                    translationX: (render.width - size.width * scale) / 2,
                    y: (render.height - size.height * scale) / 2
                ))
            var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
            layer.setTransform(fitted, at: range.start)
            var instruction = AVVideoCompositionInstruction.Configuration()
            instruction.timeRange = range
            instruction.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: layer)]
            return AVVideoCompositionInstruction(configuration: instruction)
        }
        return AVVideoComposition(configuration: configuration)
    }
}
