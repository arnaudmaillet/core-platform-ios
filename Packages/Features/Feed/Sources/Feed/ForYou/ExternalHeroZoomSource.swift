import CoreNavigation
import FeedInterface
import PostGrid
import UIKit

/// The hero source for a surface OUTSIDE this feature — a profile gallery, or
/// anything else that shows posts as grid bricks or timeline rows.
///
/// `ForYouGridZoomSource` is the same idea for the grid this package owns, and
/// the two differ in what they can assume. That one holds the page and can ask
/// it anything, re-point mid-flight, donate a live player. This one holds four
/// closures and nothing else, because the surface on the other side is in a
/// package that cannot see any of this.
///
/// What it deliberately does NOT do: re-point to the post the feed settled on.
/// The For You source lands the card on whatever the viewer paged to, which it
/// can only do because it can scroll its own grid. An external surface may not
/// even contain the settled post, so the card flies home to the tile it left
/// from — the honest answer when the origin cannot be asked about anything
/// else.
@MainActor
final class ExternalHeroZoomSource: ZoomTransitionSource {
    private let origin: SnapFeedHeroOrigin
    /// Falls back to a centred collapse at this size when the origin reports
    /// itself off screen — same rule the pin and the grid use.
    private let fallbackSide: CGFloat = 96

    init(origin: SnapFeedHeroOrigin) {
        self.origin = origin
    }

    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        if let frame = origin.frame(container) { return frame }
        // Off screen: collapse to the middle of the container rather than to a
        // rect the viewer cannot see.
        let bounds = container.bounds
        return CGRect(
            x: bounds.midX - fallbackSide / 2,
            y: bounds.midY - fallbackSide / 2,
            width: fallbackSide,
            height: fallbackSide
        )
    }

    var zoomSourceIsOnScreen: Bool { origin.isOnScreen() }

    func makeZoomFlightCard() -> any ZoomFlightCard {
        PostGridFlightCard(
            post: origin.post,
            cover: origin.cover,
            style: origin.style == .tile ? .tile : .listMedia
        )
    }

    func setZoomSourceHidden(_ hidden: Bool) {
        origin.setConcealed(hidden)
    }

    var zoomPresenterDepthView: UIView? {
        origin.depthView()
    }
}
