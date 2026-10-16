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
        if let tile = standIn as? PostGridTileStandInView {
            tile.installLiveMedia(clip)
        } else {
            // A media card's twin: its picture first, its words over it.
            clip.frame = standIn.bounds
            clip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            standIn.insertSubview(clip, at: min(1, standIn.subviews.count))
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
