import CoreModels
import CoreNavigation
import MediaPlayback
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
    /// The tile the viewer left from, kept for the whole push/pop pair.
    ///
    /// This is the landing target, whatever they scrolled to in between: the
    /// grid is not moved, so the departure tile is still exactly where it was
    /// when they tapped it, and the active post is brought TO that slot rather
    /// than the grid being taken to the active post.
    private let departureID: PostID
    /// The post the destination is showing right now, injected so this type
    /// never has to know what a feed is.
    private let activePostID: () -> PostID?
    /// The feed's own copy of a post, for the case where the page being landed
    /// in no longer holds it. Optional: a caller with no corpus to consult
    /// simply cannot land on a post the page has dropped, which is where this
    /// stood before.
    private let landedModel: ((PostID) -> GalleryPost?)?
    /// Falls back to a centred collapse at this size when the anchor has no
    /// realized cell — the same rule the pin uses when it is panned off-screen.
    private let fallbackSide: CGFloat = 96

    /// The gallery, and ONLY the gallery, is what the depth cue recedes — see
    /// `zoomPresenterDepthView`.
    private weak var depthView: UIView?

    /// Hands over the tapped tile's already-rendering surface and parks its
    /// player for the destination. `nil` when the tile was not playing.
    private let donateLive: (() -> VideoRenderView?)?

    /// Set the moment a dismissal stages, and never cleared: this source
    /// serves one push/pop pair, so every card built after staging belongs
    /// to a return flight.
    private var isStagingDismissal = false

    init(
        page: ForYouGridPage,
        tappedID: PostID,
        activePostID: @escaping () -> PostID?,
        landedModel: ((PostID) -> GalleryPost?)? = nil,
        depthView: UIView?,
        hoistLive: ((UIView, CGRect, UICoordinateSpace, CGFloat) -> Bool)? = nil,
        poseHoisted: ((CGRect, UICoordinateSpace, CGFloat) -> Void)? = nil,
        releaseHoisted: (() -> UIView?)? = nil,
        donateLive: (() -> VideoRenderView?)? = nil
    ) {
        self.hoistLive = hoistLive
        self.poseHoisted = poseHoisted
        self.releaseHoisted = releaseHoisted
        self.page = page
        anchorID = tappedID
        departureID = tappedID
        self.activePostID = activePostID
        self.landedModel = landedModel
        self.depthView = depthView
        self.donateLive = donateLive
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
        if let hero = page?.hero(for: anchorID, in: container), zoomSourceIsOnScreen {
            return hero.frame
        }
        // ⚠️ THE ROW ITSELF, BEFORE THE MIDDLE OF THE SCREEN.
        //
        // A close ends up anchored to a post with no hero more often than the
        // opening ever could: the anchor is re-pointed at whatever the viewer
        // paged to, and if that post cannot be landed on the anchor stays the
        // DEPARTURE post — which, for a text post opened as a window, has no
        // media either. Both specific rects then answer nil and the card
        // collapsed into the centre of the screen, flying a blank placeholder.
        // Reported exactly that way: "the transition window returns to the
        // middle of the screen".
        //
        // The row is always an honest answer: it is where that post lives, and
        // the card lands on the card the viewer is coming back to.
        if zoomSourceIsOnScreen, let row = page?.rowFrame(for: anchorID, in: container) {
            return row
        }
        #if DEBUG
        // `-zoom-live-log`: the centre is the answer of no answer, and on its
        // own it says nothing about WHY — no rect for this post, or no row on
        // screen at all. Reaching here at all means both.
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] NO RECT anchor=\(anchorID.rawValue)"
                + " onScreen=\(zoomSourceIsOnScreen)"
                + " inFeed=\(page?.post(for: anchorID) != nil)")
        }
        #endif
        return ZoomTransitionGeometry.centeredFallback(in: container.bounds, side: fallbackSide)
    }

    var zoomSourceIsOnScreen: Bool {
        page?.isPostVisible(anchorID) ?? false
    }

    /// The tile's twin: the same cover pixels the viewer is looking at, in the
    /// shape that tile actually has (a mosaic brick and a timeline row's
    /// preview round differently and carry different furniture).
    func makeZoomFlightCard() -> any ZoomFlightCard {
        let appearance = page?.heroAppearance(for: anchorID)
        let card = PostGridFlightCard(
            post: page?.post(for: anchorID) ?? Self.placeholder(id: anchorID),
            cover: appearance?.cover,
            style: appearance?.style ?? .tile
        )
        #if DEBUG
        // Whether the card had a texture to show on frame 0. `heroAppearance`
        // reads the tile's `renderedCover` synchronously and the initialiser
        // assigns it immediately, so a bound cover is the expected case — this
        // exists to catch the exception, where the card is posed over the tile
        // with nothing but its own background colour.
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f card FRAME0 cover=%@ style=%@",
                         CACurrentMediaTime(),
                         appearance?.cover == nil ? "NIL" : "bound",
                         String(describing: appearance?.style ?? .tile)))
        }
        #endif
        // An autoplaying tile hands its RUNNING surface to the card. Donating
        // the live view is preferred over mirroring onto the card's own: a
        // mirrored layer is blank for ~100ms while the source is already
        // hidden, which is the flash at the start of the flight. Moving the
        // layer that is mid-playback has no such window.
        //
        // PRESENT only. On a dismissal the card must fly what the VIEWER is
        // watching — the destination page's playback. This grid-side attach
        // resolves by URL, and with the cold-open race having minted a
        // second player for the same asset (measured: two renderers, one
        // URL, different clocks) that lookup could prime the card from the
        // TILE's playhead, seconds from the page's — the frame-0 jump at
        // the start of a dismiss. Declining lets `ZoomFlight.build` fall
        // through to `zoomDonateLiveMediaView`, which attaches alongside
        // the page's own surface by IDENTITY.
        if !isStagingDismissal, let donateLive, let donated = donateLive() {
            card.adoptZoomLiveMediaView(donated)
        }
        return card
    }

    /// The same donation, asked again while the card is already in the air.
    ///
    /// The build-time ask above can only report what the grid held AT THE TAP,
    /// and a tile is routinely granted its player by that very tap: the focus
    /// pass starts it, the URL resolves a turn later, the first frame decodes
    /// after that. Answering nil once therefore says "not yet", never "never",
    /// and the flight is entitled to keep asking for as long as the answer
    /// could still change.
    ///
    /// PRESENT only, for exactly the reason the build-time ask is: a dismissal
    /// must fly the page's playhead, not the tile's.
    func zoomLiveMediaSurfaceIfReady() -> UIView? {
        guard !isStagingDismissal, let donateLive else { return nil }
        return donateLive()
    }

    /// Takes the card's live surface at landing, so the tile renders the frame
    /// the card was showing instead of starting a blank layer.
    /// True once the landing tile's own surface is rendering — or when the tile
    /// has no video at all, which is nothing to wait for.
    var zoomLandingMediaIsReady: Bool {
        page?.isLandingPlaybackReady(for: anchorID) ?? true
    }

    /// Lays the landing tile out before the card is unmounted, so the cell's
    /// subview composition is resolved rather than pending.
    func zoomFinalizeLanding() {
        page?.finalizeLandingLayout(for: anchorID)
    }

    /// Hoists the dismissal's live surface into the tab-bar-level host.
    private let hoistLive: ((UIView, CGRect, UICoordinateSpace, CGFloat) -> Bool)?
    private let poseHoisted: ((CGRect, UICoordinateSpace, CGFloat) -> Void)?
    private let releaseHoisted: (() -> UIView?)?

    func zoomHoistLiveMedia(_ view: UIView, at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat) -> Bool {
        hoistLive?(view, rect, space, cornerRadius) ?? false
    }

    func zoomPoseHoistedMedia(at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat) {
        poseHoisted?(rect, space, cornerRadius)
    }

    func zoomReleaseHoistedMedia() -> UIView? {
        releaseHoisted?()
    }


    func zoomAdoptLiveMediaView(_ view: UIView) {
        guard let view = view as? VideoRenderView else { return }
        page?.adoptLivePlayback(view, for: anchorID)
    }

    func setZoomSourceHidden(_ hidden: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f source hidden=%@",
                         CACurrentMediaTime(), hidden ? "true" : "false"))
        }
        #endif
        page?.setHeroHidden(hidden, for: anchorID)
        // Restoring the source is the end of the flight, whichever way it went:
        // hand the grid's inset back so it tracks the safe area again.
        if !hidden {
            page?.endHeroFreeze()
        }
    }

    /// Bring the post the feed ended on TO the tile the viewer left from, then
    /// anchor there.
    ///
    /// The grid is deliberately not scrolled. Scrolling it to reach the active
    /// post's own tile moves the whole gallery under the viewer while a card is
    /// about to land on it — and the tile they launched from, which is the frame
    /// the flight reads as home, is still exactly where they left it. Nothing
    /// can have scrolled the grid in the meantime: it has been covered by the
    /// feed the whole time.
    ///
    /// Order matters. The swap goes first, because it is what makes the
    /// anchor's id resolve to the departure slot; the hide goes last, because
    /// the swap reloads those two cells and a cell dequeued before the flag was
    /// set would come back visible.
    func zoomSourceWillStageDismissal() {
        // From here on, cards belong to return flights — see `makeZoomFlightCard`.
        isStagingDismissal = true
        // Pin the grid's inset first, before anything reads a rect from it: the
        // pop animates the safe area, and an unpinned grid keeps drifting under
        // the flight. See `ForYouGridPage.beginHeroFreeze`.
        page?.beginHeroFreeze()
        // ⚠️ ONLY A POST THIS FLIGHT CAN LAND ON.
        //
        // The adoption is what makes a dismissal return to the card the viewer
        // ENDED on, and until now it could not reach a list at all, so the
        // question never arose. It does now: page from a photograph to a
        // TEXT-only post and the landed row has no media to fly to —
        // `heroAppearance` answers nil for one on purpose, and the note there
        // records why (a card impersonating a page of comments is the disease
        // the reveal exists to avoid). Adopting it anyway would leave the
        // flight with no rect and collapse it to the middle of the screen.
        //
        // So a text landing is declined and the flight goes home to the tile it
        // left from — the wrong post, and the honest answer this driver can
        // give. What that case actually wants is the REVEAL, chosen at the
        // grab rather than at the tap, which is a change to which driver is
        // installed rather than to where it lands.
        // ⚠️ THE MODEL DECIDES, NOT A REALIZED CELL — see `canLandHero(on:)`.
        //
        // This asked `heroAppearance`, which reads the cell, and the post being
        // dismissed is the one the viewer paged to: the further they went, the
        // more certain the row was outside the realized window and the answer
        // was "cannot fly" for a photograph that plainly could. Nine pages down
        // it declined every time, and the flight landed on the departure tile —
        // the viewer closed one post and watched another land.
        let landed = activePostID()
        // Resolved from the page when it has it, and from the feed's whole
        // corpus when it does not — the adoption inserts in that case.
        let model = landed.flatMap { page?.post(for: $0) ?? landedModel?($0) }
        if let landed, let model, page?.canLandHero(on: model) == true,
           page?.adoptPost(landed, intoSlotOf: departureID, orInsert: model) == true {
            // The active post now occupies the departure slot, so anchoring to
            // it lands on that tile without moving anything.
            anchorID = landed
        } else {
            // Nothing moved: either the viewer never left the tile, or the feed
            // settled on a post this grid no longer holds. Both land on the
            // departure tile itself rather than on a rect that no longer exists.
            anchorID = departureID
        }
        // The scope was opened for the TAPPED post; the landing is on this one.
        // Without this the reconcile that fires when the tile is unhidden stops
        // the surface it has just been handed.
        page?.retargetPlaybackHandoff(to: anchorID)
        // Visible for the whole return: the card is landing ON this tile.
        page?.setHeroHidden(true, for: anchorID, conceals: false)
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
