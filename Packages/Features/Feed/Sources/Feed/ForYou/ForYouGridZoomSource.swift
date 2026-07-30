import CoreModels
import CoreNavigation
import PostGrid
import UIKit

/// The grid side of the hero transition: the tapped tile. Mirror of
/// `MapPinZoomSource`, and it exists for the same reason — the shared
/// machinery needs a rect, a card and a way to hide the original, and knows
/// nothing about what produced them.
///
/// **Where it differs from the pin.** A pin is a fixed thing on a map: the
/// flight leaves from it and returns to it. A grid tile is a doorway into a
/// *paging* feed, so the post the viewer dismisses on is often not the one they
/// tapped. This source therefore re-points at the active post before a
/// dismissal stages (`zoomSourceWillStageDismissal`) and lands the card on
/// *that* post's tile, scrolling it into view if the viewer had moved past it.
/// The alternative — flying back to the tapped tile regardless — puts the card
/// down on content the viewer is no longer looking at.
@MainActor
final class ForYouGridZoomSource: ZoomTransitionSource {
    private weak var page: ForYouGridPage?
    /// The post the flight is currently anchored to. Starts at the tapped
    /// post and re-points to whatever the feed settled on.
    private var anchorID: PostID
    /// The post the destination is showing right now, injected so this type
    /// never has to know what a feed is.
    private let activePostID: () -> PostID?
    /// Falls back to a centred collapse at this size when the anchor has no
    /// realized cell — the same rule the pin uses when it is panned off-screen.
    private let fallbackSide: CGFloat = 96

    /// The gallery, and ONLY the gallery, is what the depth cue recedes — see
    /// `zoomPresenterDepthView`.
    private weak var depthView: UIView?

    init(
        page: ForYouGridPage,
        tappedID: PostID,
        activePostID: @escaping () -> PostID?,
        depthView: UIView?
    ) {
        self.page = page
        anchorID = tappedID
        self.activePostID = activePostID
        self.depthView = depthView
    }

    /// The pager, not the whole screen.
    ///
    /// The cue is a scale about its view's centre, so anything inside it drifts
    /// toward that centre as well as shrinking. Applied to the whole screen that
    /// dragged the filter tray 17pt upward and shrank it 5% while the tab bar —
    /// which lives outside the presenter and so never saw the transform — stayed
    /// exactly put. Measured, both of them. Half the bottom furniture sliding and
    /// half of it nailed down reads as a bug, not as depth.
    ///
    /// Naming the pager puts the recede on the content and leaves every piece of
    /// this screen's chrome at its layout position. The chrome still darkens with
    /// the flight's dim, which is opacity only and moves nothing.
    var zoomPresenterDepthView: UIView? { depthView }

    // MARK: - ZoomTransitionSource

    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        guard let hero = page?.hero(for: anchorID, in: container), zoomSourceIsOnScreen else {
            return ZoomTransitionGeometry.centeredFallback(in: container.bounds, side: fallbackSide)
        }
        return hero.frame
    }

    var zoomSourceIsOnScreen: Bool {
        page?.isPostVisible(anchorID) ?? false
    }

    /// The tile's twin: the same cover pixels the viewer is looking at, in the
    /// shape that tile actually has (a mosaic brick and a timeline row's
    /// preview round differently and carry different furniture).
    func makeZoomFlightCard() -> any ZoomFlightCard {
        let appearance = page?.heroAppearance(for: anchorID)
        return PostGridFlightCard(
            post: page?.post(for: anchorID) ?? Self.placeholder(id: anchorID),
            cover: appearance?.cover,
            style: appearance?.style ?? .tile
        )
    }

    func setZoomSourceHidden(_ hidden: Bool) {
        page?.setHeroHidden(hidden, for: anchorID)
        // Restoring the source is the end of the flight, whichever way it went:
        // hand the grid's inset back so it tracks the safe area again.
        if !hidden {
            page?.endHeroFreeze()
        }
    }

    /// Re-point at the post the feed ended on, then make sure its cell exists
    /// and is on screen before anyone reads the landing rect.
    ///
    /// Order matters and is the whole content of this method: adopt the new
    /// anchor first, because everything downstream is keyed on it; scroll only
    /// if the cell isn't already visible, so a dismissal to something already
    /// on screen never jolts the grid; then hide the (possibly freshly
    /// dequeued) cell, because a scroll can realize a *new* cell that never saw
    /// the earlier hide.
    func zoomSourceWillStageDismissal() {
        // Pin the grid's inset first, before anything reads a rect from it: the
        // pop animates the safe area, and an unpinned grid keeps drifting under
        // the flight. See `ForYouGridPage.beginHeroFreeze`.
        page?.beginHeroFreeze()
        if let landed = activePostID() {
            anchorID = landed
        }
        // Always, not only when off-screen: a *partially* visible cell is
        // "visible" by the intersection test but would have the card land
        // half under the tray or the tab bar. Centring it is idempotent when
        // it is already centred, and this runs behind the dim either way.
        page?.scrollPostIntoView(anchorID)
        page?.setHeroHidden(true, for: anchorID)
    }

    /// A tile whose post is no longer in the grid still needs a card to fly —
    /// a plain dark square, which is what a missing cover renders as anyway.
    private static func placeholder(id: PostID) -> GalleryPost {
        GalleryPost(
            id: id, kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: 0
        )
    }
}
