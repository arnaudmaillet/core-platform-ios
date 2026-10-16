import CoreModels
import MediaPlayback
import PostGrid
import UIKit

/// A tile's own parked clip, worn by the card window that carries the tile
/// home (#1294, epic #1269).
///
/// A close from a TEXT page has no picture to fly, so it goes through the
/// card window, and the window's stand-in used to be a picture — while the
/// tile's clip sat parked for exactly this close (#923/#951) and was released
/// unused. The flight's arriving picture already plays it (`returnLiveMedia`);
/// this gives the window the same: the stand-in plays the clip from where it
/// was parked, the tile takes that playback as the window lands (the reveal
/// shows the row again only on a committed close, `setConcealed(false)`), and
/// a close that springs back pauses it for the next one.
@MainActor
final class WindowReturnClips {
    private var surfaces: [PostID: VideoRenderView] = [:]

    /// `standIn`, wearing `surface()` over its cover and under its words when
    /// there is a clip to wear. Remembered for the landing.
    func dress(_ standIn: UIView?, for id: PostID, surface: () -> VideoRenderView?) -> UIView? {
        guard let standIn, let clip = surface() else { return standIn }
        let host = ScaledClipHost(clip: clip, restingSize: standIn.bounds.size)
        if let tile = standIn as? PostGridTileStandInView {
            tile.installLiveMedia(host)
        } else {
            // A media card's twin: its picture first, its words over it.
            host.frame = standIn.bounds
            host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            standIn.insertSubview(host, at: min(1, standIn.subviews.count))
        }
        surfaces[id] = clip
        return standIn
    }

    /// The clip a landing on `id` hands its tile, once.
    func takeForLanding(_ id: PostID) -> VideoRenderView? {
        surfaces.removeValue(forKey: id)
    }

    /// The close sprang back: the clip waits, paused, for the next one.
    func abandon(_ id: PostID, pause: () -> Void) {
        guard surfaces.removeValue(forKey: id) != nil else { return }
        pause()
    }

    #if DEBUG
    func debugHasClip(for id: PostID) -> Bool { surfaces[id] != nil }
    #endif
}

/// Holds a clip at ONE size and fits it to its own bounds by TRANSFORM — the
/// flight's way (`ZoomFlight` poses its live surface the same), for the same
/// reason (#1294).
///
/// ⚠️ A VIDEO SURFACE MUST NOT BE RESIZED INSIDE AN ANIMATION. The window
/// shrinks its stand-in in an animation block; a clip resized with it re-lays
/// its sample-buffer content out with AVFoundation's OWN ~0.3 s animation
/// (see `VideoRenderView.settleGeometry`), so the picture slid behind the
/// window it was in — filmed on device as the clip "animating out of step,
/// badly attached to the window". A transform is animated with the window and
/// leaves the layer's bounds alone.
///
/// Aspect-fill against the resting size the clip is laid out at, centred:
/// the stand-in's picture is cropped the same way.
final class ScaledClipHost: UIView {
    private let clip: UIView
    private let restingSize: CGSize

    init(clip: UIView, restingSize: CGSize) {
        self.clip = clip
        self.restingSize = CGSize(width: max(1, restingSize.width), height: max(1, restingSize.height))
        super.init(frame: CGRect(origin: .zero, size: self.restingSize))
        clipsToBounds = true
        isUserInteractionEnabled = false
        clip.transform = .identity
        clip.autoresizingMask = []
        clip.bounds = CGRect(origin: .zero, size: self.restingSize)
        addSubview(clip)
        layoutClip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutClip()
    }

    private func layoutClip() {
        let scale = max(bounds.width / restingSize.width, bounds.height / restingSize.height)
        clip.center = CGPoint(x: bounds.midX, y: bounds.midY)
        clip.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}
