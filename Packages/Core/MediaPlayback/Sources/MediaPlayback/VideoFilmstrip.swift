import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Frames spread evenly across a clip — the pictures a trim strip is made of.
///
/// Sibling to `VideoExporter.posterImage`: the same concern, frames out of a
/// file, at a different count.
///
/// ⚠️ **TOLERANCE ZERO ON BOTH SIDES, AND THIS REPO HAS ALREADY PAID TO LEARN
/// WHY.** `AVAssetImageGenerator` defaults to INFINITE tolerance in both
/// directions, which lets it answer every request with the nearest keyframe.
/// `Tools/IconBaker/Sources/IconBaker/VideoDocument.swift` records what that
/// does: a 24-frame sample of a clip with a 2-second GOP came back as **three
/// images repeated eight times**, with nothing erroring and nothing looking
/// wrong until someone counted. A filmstrip built that way is a plausible
/// picture of a clip nobody shot.
///
/// The cost is real — an exact time means decoding forward from a keyframe — and
/// it is the cost of the strip being true.
public struct VideoFilmstrip: Sendable {
    public init() {}

    /// `count` frames, evenly spaced, each no taller than `height` POINTS.
    ///
    /// ⚠️ **SAMPLED AT THE MIDDLE OF EACH SLICE, NOT AT ITS EDGES.** Asking at
    /// exactly zero lands on the opening fade that so much real film starts with
    /// — the same reason `posterImage` no longer samples there — and asking at
    /// exactly the duration frequently fails outright, since there is no frame
    /// at the instant a clip ends. Midpoints are inside the clip by
    /// construction.
    ///
    /// Best-effort and **ordered**: a frame that cannot be decoded is left out
    /// rather than substituted, and what comes back is in clip order however the
    /// generator chose to deliver it. A short strip is legible; a shuffled one
    /// is a lie about the clip.
    public func frames(of url: URL, count: Int, height: CGFloat) async -> [UIImage] {
        guard count > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds,
              seconds.isFinite, seconds > 0
        else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Height only: the generator scales to FIT inside this, so a zero width
        // means "whatever the clip's proportions make it". x2 because the strip
        // draws on a retina screen and a fitted picture at 1x reads as soft.
        generator.maximumSize = CGSize(width: 0, height: height * 2)

        let times = (0..<count).map { index in
            CMTime(
                seconds: seconds * (Double(index) + 0.5) / Double(count),
                preferredTimescale: 600
            )
        }

        // Keyed by the time ASKED FOR, because `actualTime` is what the
        // generator landed on and two requests can share one — which would
        // collapse two strip cells into one entry and shorten the strip.
        var byRequest: [CMTime: UIImage] = [:]
        for await result in generator.images(for: times) {
            if case .success(let requested, let image, _) = result {
                byRequest[requested] = UIImage(cgImage: image)
            }
        }
        return times.compactMap { byRequest[$0] }
    }
}
