import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Frames out of a clip at named moments — the pictures a timeline's film is
/// made of.
///
/// Sibling to `VideoExporter.posterImage`: the same concern, many at a time.
///
/// ⚠️ **IT TAKES TIMES, NOT A COUNT, AND THAT IS THE WHOLE DIFFERENCE.** This
/// used to answer "give me N frames spread across the clip", which forces the
/// caller to decide the strip's entire contents in one go. A timeline that
/// scrolls cannot: a four-minute clip at sixty points a second is fourteen
/// thousand points of film, and at a 54pt square tile that is two hundred and
/// sixty thumbnails — 52 MB of decoded pixels for a band 74pt tall, nearly all
/// of it off screen. Asking by time lets the strip decode the part a person is
/// looking at and nothing else.
///
/// ⚠️ **ONE GENERATOR PER CLIP, KEPT.** A generator carries the reader it has
/// already opened; building one per batch pays for that open every time the
/// strip scrolls. `VideoPlaybackController.frameGenerator(for:)` keeps one for
/// the same reason.
@MainActor
public final class VideoFilmstrip {
    public init() {}

    private var openURL: URL?
    private var openHeight: CGFloat = 0
    private var generator: AVAssetImageGenerator?

    /// How far either side of a requested time the generator may wander.
    ///
    /// ⚠️ **DERIVED FROM THE SPACING, AND A CONSTANT HERE IS WRONG IN BOTH
    /// DIRECTIONS.** `AVAssetImageGenerator` defaults to INFINITE tolerance both
    /// ways, which answers every request with the nearest sync sample. Measured
    /// on a 10-minute 1080p30 clip with a 2-second GOP: 600 requests one second
    /// apart came back as **300 distinct frames**, and 40 requests over 8 seconds
    /// came back as **five**. `Tools/IconBaker` records the same trap from the
    /// other end — 24 samples, three pictures repeated eight times.
    ///
    /// Zero is not the answer either. Measured on the same clip: tolerance
    /// strictly below half the sampling interval is fully distinct and costs
    /// ~8.5 ms a frame; tolerance at or above the interval snaps to keyframes and
    /// costs ~1.5 ms — six times cheaper. So the rule is **just under half the
    /// spacing**: every frame is distinct by construction, and a coarse strip
    /// automatically gets the cheap keyframe path because its half-spacing window
    /// is wide enough to contain one.
    ///
    /// ⚠️ **AND THE RULE HAS A FLOOR IT DOES NOT ENFORCE — MEASURED.** Below
    /// roughly one frame interval the window stops containing a frame at all and
    /// the generator returns NOTHING rather than something near. Probed on a
    /// 30fps clip, asking for three moments one spacing apart:
    ///
    /// ```
    /// spacing 0.500  tolerance 0.2250  ->  3 of 3
    /// spacing 0.100  tolerance 0.0450  ->  3 of 3
    /// spacing 0.050  tolerance 0.0225  ->  3 of 3
    /// spacing 0.033  tolerance 0.0149  ->  1 of 3
    /// ```
    ///
    /// It is not reachable from the timeline: a tile is 54pt and the closest zoom
    /// is 320 points a second, so the tightest spacing that can be asked for is
    /// 0.169s — five times the cliff. `MediaTimeliningTests` pins that, so raising
    /// the zoom ceiling past it turns a test red rather than emptying the strip.
    ///
    /// A single frame has no spacing and gets the exact answer.
    public static func tolerance(forSpacingSeconds spacing: Double) -> Double {
        guard spacing.isFinite, spacing > 0 else { return 0 }
        return spacing * 0.45
    }

    /// Frames at the given SOURCE seconds, keyed by the second that was asked
    /// for.
    ///
    /// ⚠️ **KEYED BY THE REQUEST, NEVER BY `actualTime`.** `actualTime` is where
    /// the generator landed, and two requests can land on one frame — keying by
    /// it would collapse two tiles into one entry and leave a hole in the strip
    /// that looks like a decode failure.
    ///
    /// Best-effort: a time that cannot be decoded is simply absent, and the
    /// caller leaves that tile showing whatever it had.
    public func frames(
        of url: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
    ) async -> [Double: UIImage] {
        guard !seconds.isEmpty, height > 0 else { return [:] }
        guard let generator = generator(for: url, height: height) else { return [:] }

        let slack = CMTime(seconds: Self.tolerance(forSpacingSeconds: spacing), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack

        // ⚠️ ONE BATCH, NOT A LOOP OF `image(at:)`. Measured 10.5 ms a frame
        // against 30.5 for a serial loop on the same reused generator — the
        // header's "far greater efficiency" is a threefold difference, not a
        // turn of phrase.
        let times = seconds.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var byRequest: [Double: UIImage] = [:]
        for await result in generator.images(for: times) {
            guard case .success(let requested, let image, _) = result else { continue }
            guard let second = seconds.first(where: {
                abs($0 - requested.seconds) < 0.001
            }) else { continue }
            byRequest[second] = UIImage(cgImage: image)
        }
        return byRequest
    }

    private func generator(for url: URL, height: CGFloat) -> AVAssetImageGenerator? {
        if let generator, openURL == url, openHeight == height { return generator }
        let made = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        made.appliesPreferredTrackTransform = true
        // Height only: the generator scales to FIT inside this and never scales
        // up, so a zero width means "whatever the clip's proportions make it".
        // ⚠️ THIS IS A MEMORY CONTROL, NOT A SPEED ONE — measured at 2.93 ms a
        // frame native against 3.06 at thumbnail size, which is no difference at
        // all. What it decides is the pixels kept: 1920x1080 is 8.3 MB a frame
        // and a 54pt tile at 3x is 198 KB.
        made.maximumSize = CGSize(width: 0, height: height * UIScreen.main.scale)
        openURL = url
        openHeight = height
        generator = made
        return made
    }

}
