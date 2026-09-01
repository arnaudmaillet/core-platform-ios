import UIKit

/// How a transition card carries the picture it is LEAVING.
///
/// ## Why this is not two copies
///
/// Two cards fly a departing page home — the map's marker and the grid's tile —
/// and both hold that page's picture as a cover behind their own content. The
/// arithmetic below is eight lines, it was wrong once in a way that took two
/// filmed reports to name, and a second hand-written copy would agree on the
/// day it was written and drift from the first correction onward. So it is
/// written once, here, where both can reach it.
///
/// ## ⚠️ A UNIFORM SCALE, NOT AN ASPECT-FILL RESIZE
///
/// Aspect-filling a cover that is resized to the card recomputes the crop every
/// frame: as the card narrows toward its landing the picture keeps its height
/// and loses its sides, so the viewer watches the media get cut away rather
/// than travel. Filmed twice and reported both times as the departure content
/// "truncating in the transition window".
///
/// A tile landing hides it — its aspect is close to the page's, so the recrop
/// is small — and a marker cannot: the aspect goes from a full screen to a
/// circle. That is why only the marker was ever reported, and why the tile is
/// here anyway: it is the same defect, waiting for a page shape that exposes it.
///
/// Laid out at the DEPARTURE's size and scaled to COVER the card instead, the
/// picture shrinks as one thing and still fills the window at every instant.
/// It is the model a flight already drives live media with, and the reason is
/// the same.
public enum DepartureCoverLayout {
    /// Poses `cover` inside `bounds`, and returns the departure size to carry
    /// into the next pass.
    ///
    /// ⚠️ THE BASE IS THE LARGEST SIZE SEEN, not the size at which the picture
    /// was handed in. A flight is given its cover before it is ever sized (a
    /// card is born at `.zero`) and may be handed a late one mid-descent, so
    /// the moment of the call says nothing about where the card started.
    /// Taking the maximum reads the departure off the animation itself, and
    /// degrades honestly for a card that only ever shrinks under a transform:
    /// its bounds never grow, the scale stays 1, and the cover behaves exactly
    /// as it did before any of this existed.
    ///
    /// Pass the previous return value back in. Nil out on a cleared picture.
    public static func apply(
        to cover: UIImageView, in bounds: CGRect, departureBase: CGSize?
    ) -> CGSize? {
        guard cover.image != nil, bounds.width > 0, bounds.height > 0 else {
            cover.transform = .identity
            cover.frame = bounds
            return departureBase
        }
        let base = CGSize(
            width: max(departureBase?.width ?? 0, bounds.width),
            height: max(departureBase?.height ?? 0, bounds.height)
        )
        cover.transform = .identity
        cover.bounds = CGRect(origin: .zero, size: base)
        let scale = max(bounds.width / base.width, bounds.height / base.height)
        cover.transform = CGAffineTransform(scaleX: scale, y: scale)
        cover.center = CGPoint(x: bounds.midX, y: bounds.midY)
        return base
    }
}
