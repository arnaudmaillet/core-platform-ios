import CoreGraphics
import CoreImage

/// Draws overlays: text and emoji into pictures, and every overlay onto a
/// finished frame.
///
/// ⚠️ **ONE RASTERISER FOR THE EXPORT, THE PHOTO BAKE AND THE EDITOR'S VIEWS.**
/// The editor shows overlays as views over the page rather than burning them
/// into its preview — so they can move at 60fps under a finger — and those views
/// draw the image `image(for:outputWidth:scale:)` returns. What the author drags
/// is therefore the very picture that gets published.
///
/// ⚠️ **CORE TEXT, NOT UIKit TEXT DRAWING.** It runs on the compositor's queue
/// and on detached photo renders; nothing here may need the main actor.
public enum OverlayRasterizer {
    /// `overlays` drawn over `image` in array order — the last on top — at
    /// `time` seconds into the film (a photograph passes 0). Stickers come from
    /// `artwork`; one it cannot supply is skipped and everything else is drawn.
    ///
    /// ⚠️ **A STUB THAT RETURNS `image`.** The overlay slice (S3) fills it: each
    /// overlay rasterised once per output size, scaled, turned and placed with
    /// the y axis flipped (placements are top-left, Core Image is bottom-left),
    /// then composited over. No screen can add an overlay until then.
    public static func composite(
        _ overlays: [FrameOverlay], over image: CIImage, time: Double,
        artwork: (any OverlayArtwork)?
    ) -> CIImage {
        image
    }

    /// The picture of one text or emoji overlay, for a finished frame
    /// `outputWidth` pixels wide, at placement scale `scale` — upright and
    /// unplaced. Nil for a sticker, whose pictures come from `OverlayArtwork`.
    ///
    /// ⚠️ **A STUB THAT RETURNS NIL.** The overlay slice (S3) fills it; the
    /// editor's overlay views (S9) draw what it returns.
    public static func image(
        for content: FrameOverlay.Content, outputWidth: CGFloat, scale: Double
    ) -> CGImage? {
        nil
    }
}
