import CoreModels
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
/// else. It is also the answer a SORTED list needs: a place's Activity tab is
/// ranked, and a close that re-pointed into it would move the post the viewer
/// left under the card that is landing on it.
///
/// The card still has to LOOK like where the viewer is leaving from, though,
/// and that is a separate question from where it lands. `settle` supplies it:
/// the feed's own settled page and the picture that page is drawing, asked at
/// staging, dissolved into the departure tile's cover on the way home.
@MainActor
final class ExternalHeroZoomSource: ZoomTransitionSource {
    private let origin: SnapFeedHeroOrigin
    /// Falls back to a centred collapse at this size when the origin reports
    /// itself off screen — same rule the pin and the grid use.
    private let fallbackSide: CGFloat = 96
    /// Where the viewer stopped, and what that page is showing. Nil for a
    /// caller with no pager behind the flight, which keeps the card single-
    /// pictured exactly as it has always been.
    private let settle: (() -> (id: PostID?, cover: UIImage?))?
    /// The picture the card must wear at the page end, resolved at staging.
    /// Nil on every present, and on any dismissal that leaves from the post it
    /// opened — which is the row that must not blend at all, since blending
    /// there would dissolve one picture into itself.
    private var departurePicture: UIImage?

    init(
        origin: SnapFeedHeroOrigin,
        settle: (() -> (id: PostID?, cover: UIImage?))? = nil
    ) {
        self.origin = origin
        self.settle = settle
    }

    /// Asks where the viewer stopped, and keeps the answer only when it is
    /// somewhere else.
    ///
    /// ⚠️ Compared against `origin.post.id` rather than against nothing: the
    /// picture and the id have to agree, and a page showing the SAME post is
    /// showing the card's own cover. Handing that back as a second operand
    /// would cross-fade a photograph with itself — invisible when it works and
    /// indistinguishable from a soft landing when it does not.
    private var isStagingDismissal = false

    func zoomSourceWillStageDismissal() {
        isStagingDismissal = true
        defer { debugLogBlend() }
        guard let settled = settle?(), let id = settled.id, id != origin.post.id else {
            departurePicture = nil
            return
        }
        departurePicture = settled.cover
    }

    /// `-zoom-blend-log`: the same channel the map's flight reports on, because
    /// the two answer the same question and a run comparing them should not
    /// have to read two formats. Says the ids as well as the outcome: an inert
    /// blend is only correct if the two of them actually match.
    private func debugLogBlend() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-zoom-blend-log") else { return }
        print("[zoom-blend] departure=\(settle?().id?.rawValue ?? "nil")"
            + " arrival=\(origin.post.id.rawValue)"
            + " cover=\(departurePicture == nil ? "none" : "picture")")
        #endif
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
        let card = PostGridFlightCard(
            post: origin.post,
            cover: origin.cover,
            style: origin.style == .tile ? .tile : .listMedia
        )
        card.setDeparturePicture(departurePicture)
        // ⚠️ PRESENT ONLY. A dismissal must fly the PAGE's playhead, not the
        // row's — the two are seconds apart once the page has been playing, and
        // the dismissal's own donation resolves by identity from the page.
        if !isStagingDismissal, let donated = origin.donateLiveMedia?() {
            card.adoptZoomLiveMediaView(donated)
        }
        return card
    }

    /// Asked again while the card is already in the air.
    ///
    /// The build-time ask can only report what the row held AT THE TAP, and a
    /// row is routinely granted its player by that very tap: the focus pass
    /// starts it, the URL resolves a turn later, the first frame decodes after
    /// that. One nil says "not yet", never "never".
    func zoomLiveMediaSurfaceIfReady() -> UIView? {
        guard !isStagingDismissal else { return nil }
        return origin.donateLiveMedia?()
    }

    func setZoomSourceHidden(_ hidden: Bool) {
        origin.setConcealed(hidden)
    }

    var zoomPresenterDepthView: UIView? {
        origin.depthView()
    }
}
