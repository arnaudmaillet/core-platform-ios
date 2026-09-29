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

    /// The card in the air, so a picture that loads after take-off can still
    /// reach it (`SnapFeedHeroOrigin.pagePictureOf`). Weak: the flight owns
    /// it, and a landed flight must not be revived by a late image.
    private weak var flyingCard: PostGridFlightCard?

    /// Whether the source draws something OTHER than the post — a friend's
    /// face. Asked of both picture fields, because the peek (`pagePicture`)
    /// is nil whenever the cache was cold at the tap, and a face with a cold
    /// cache is still a face: reading its absence as "a tile" skipped the
    /// close's blend entirely and flew the face alone.
    private var drawsFace: Bool {
        origin.pagePicture != nil || origin.pagePictureOf != nil
    }

    func zoomSourceWillStageDismissal() {
        isStagingDismissal = true
        // FIRST, before anything here or in the flight reads a rect: the
        // origin may have to pin a scroll view or bring itself back into view
        // (`SnapFeedHeroOrigin.willStageDismissal`). The flight asks `frame`
        // straight after this returns.
        origin.willStageDismissal()
        defer { debugLogBlend() }
        // ⚠️ A FACE IS NEVER THE POST. A source drawing something other than
        // the post (`SnapFeedHeroOrigin.pagePicture`) blends on EVERY close —
        // from whatever the page shows, back to the face — including a close
        // from the very post it opened, which for a tile would be a picture
        // dissolving into itself.
        //
        // The page's own still first (the picture on screen, whatever page
        // of a carousel); a VIDEO page has none, so then the post's own
        // picture — of the post the viewer ENDED on, not the one the face
        // opened — and only then the opening's peek, which is that post's.
        // The page's live surface, when it flies, covers this operand anyway;
        // it is the floor under a surface that has not drawn.
        if drawsFace {
            let settled = settle?()
            let id = settled?.id ?? origin.post.id
            departurePicture = settled?.cover
                ?? origin.pagePictureOf?(id) { [weak self] late in
                    self?.departurePictureArrived(late)
                }
                ?? (id == origin.post.id ? origin.pagePicture : nil)
            return
        }
        guard let settled = settle?(), let id = settled.id, id != origin.post.id else {
            departurePicture = nil
            return
        }
        departurePicture = settled.cover
    }

    /// A close's departure picture that loaded after staging: kept for any
    /// card built from here on, and handed to the one already in the air.
    private func departurePictureArrived(_ image: UIImage) {
        guard isStagingDismissal, departurePicture == nil else { return }
        departurePicture = image
        flyingCard?.setLateDeparturePicture(image)
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
            style: origin.style == .tile ? .tile : .listMedia,
            cornerRadius: origin.cornerRadius,
            cornerCurve: origin.cornerCurve,
            drawsPost: !drawsFace
        )
        flyingCard = card
        // On the OPENING the far end is the page's picture only when the
        // source is not drawing the post (a face); on a close it is whatever
        // staging resolved.
        //
        // ⚠️ A face's opening ASKS for the picture when the tap's peek missed,
        // and takes it mid-air when it lands — the map's late departure cover
        // (`MapPinZoomSource.awaitDepartureCover`), for the same reason: the
        // flight is never held for a picture, and a picture that arrives in
        // time is never thrown away.
        let picture = isStagingDismissal
            ? departurePicture
            : origin.pagePicture ?? origin.pagePictureOf?(origin.post.id) { [weak card] late in
                card?.setLateDeparturePicture(late)
            }
        card.setDeparturePicture(picture)
        if let overlay = origin.restingOverlay?() {
            card.installRestingOverlay(overlay)
        }
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

    /// ⚠️ FALSE FOR A FACE THAT CAN DONATE NOTHING — a friend's story.
    ///
    /// The destination stands its own playback down for a presenting flight
    /// on the premise that the card is flying ITS player (see the requirement).
    /// A face flies no player and never will: nothing on its screen draws the
    /// friend's post, so there is no surface to donate at the tap and no row
    /// to be granted one mid-air. The premise was false, and what it bought
    /// was a story opening on a poster — the card dissolved from the face to
    /// the post's still and the clip started only once the page had landed.
    ///
    /// Answering false lets the page decode from take-off, and the flight's
    /// mirroring retry (`ZoomLiveMediaRetry.arm(mirroring:)`) brings its
    /// first frame into the card mid-air — the marker's route, which is the
    /// other source that flies no player of its own. Every source that CAN
    /// donate keeps the default: its card is, or is about to be, flying the
    /// page's player, and a page starting its own would blank it.
    var zoomFlightCarriesLivePlayer: Bool {
        !(drawsFace && origin.donateLiveMedia == nil)
    }

    /// A close's landing: the item takes the surface the card was flying, so
    /// it is drawing before the card is taken away — see
    /// `SnapFeedHeroOrigin.adoptLandingLiveMedia`. A no-op for an origin that
    /// cannot, which is today's landing.
    func zoomAdoptLiveMediaView(_ view: UIView) {
        origin.adoptLandingLiveMedia?(view)
    }

    /// The card is held over the landing until the item is drawing.
    var zoomLandingMediaIsReady: Bool {
        origin.landingMediaIsReady?() ?? true
    }

    func setZoomSourceHidden(_ hidden: Bool) {
        origin.setConcealed(hidden)
    }

    var zoomPresenterDepthView: UIView? {
        origin.depthView()
    }
}
