import CoreModels
import CoreNavigation
import EmoteKit
import MediaPlayback
import PostGrid
import UIKit

/// The grid side of the hero transition: the tapped tile. Mirror of
/// `MapPinZoomSource`, and it exists for the same reason — the shared
/// machinery needs a rect, a card and a way to hide the original, and knows
/// nothing about what produced them.
///
/// **A close always comes home to the tile that was tapped** (the owner,
/// 2026-10-16, #1269/#1283): a grid tile is a doorway into a *paging* feed, so
/// the post the viewer dismisses on is often not the one they tapped — and the
/// card then lands on the tapped tile, the page's picture crossfading into the
/// tile's own clip (`landsOnAnotherPost`). Nothing in the grid moves to meet
/// the close.
@MainActor
final class ForYouGridZoomSource: ZoomTransitionSource {
    private weak var page: ForYouGridPage?
    /// The post the flight is anchored to: the tapped one, whatever the feed
    /// settled on (#1283).
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
    /// Which page of the landed post's collection the destination is showing,
    /// so the row can be put on it before the card arrives. Nil for a caller
    /// with no collections to speak of.
    private let activeMediaPage: (() -> Int?)?
    /// Falls back to a centred collapse at this size when the anchor has no
    /// realized cell — the same rule the pin uses when it is panned off-screen.
    private let fallbackSide: CGFloat = 96

    /// The gallery, and ONLY the gallery, is what the depth cue recedes — see
    /// `zoomPresenterDepthView`.
    private weak var depthView: UIView?

    /// Hands over the tapped tile's already-rendering surface and parks its
    /// player for the destination. `nil` when the tile was not playing.
    private let donateLive: (() -> VideoRenderView?)?

    /// The picture of the post the viewer is actually LOOKING at, for a close
    /// that lands somewhere else.
    ///
    /// ⚠️ WITHOUT THIS THE CARD TAKES OFF WEARING A PHOTOGRAPH NOBODY HAS SEEN.
    /// The card's own cover is read from the LANDING row (`heroAppearance(for:
    /// anchorID)`), and since a list keeps its order the landing is the row the
    /// viewer opened — almost never the post they paged to. Filmed: a grab
    /// leaving a harbour photograph showed a dog from its first frame, and the
    /// reverse case, where the departure held a live surface, showed the
    /// departure for the whole drag and then snapped to the landing in one
    /// frame as the card was removed. Both are the same missing operand.
    ///
    /// This is the cut `setDeparturePicture` exists for, and every other
    /// presenter of this feed already hands it in — `PlaceProfileViewController`
    /// and `ExternalHeroZoomSource`. This source was the only one that never
    /// learned what the settled page was showing.
    private let settledCover: (() -> UIImage?)?

    /// Set the moment a dismissal stages, and never cleared: this source
    /// serves one push/pop pair, so every card built after staging belongs
    /// to a return flight.
    private var isStagingDismissal = false

    /// Held only so the display link outlives this method; it stops itself.
    private var landingRetry: LandingLiveMediaRetry?

    /// Whether this close lands on a post OTHER than the one the viewer is
    /// closing — a list keeps its order, so paging on and closing comes home
    /// to the row that was tapped (#923). Set when the return card is built.
    private var landsOnAnotherPost = false
    /// The landing row's own moving picture, as the card's arriving operand
    /// carries it: the row's parked return player, or a surface joined to a
    /// row that is still playing. What the landing hands the row on such a
    /// close — never the card's departure surface, which is the PAGE's post.
    private weak var landingSurface: VideoRenderView?
    /// Whether the row took `landingSurface`'s playback at the landing.
    private var didAdoptLanding = false

    init(
        page: ForYouGridPage,
        tappedID: PostID,
        activePostID: @escaping () -> PostID?,
        activeMediaPage: (() -> Int?)? = nil,
        depthView: UIView?,
        settledCover: (() -> UIImage?)? = nil,
        donateLive: (() -> VideoRenderView?)? = nil
    ) {
        self.page = page
        anchorID = tappedID
        departureID = tappedID
        self.activePostID = activePostID
        self.activeMediaPage = activeMediaPage
        self.depthView = depthView
        self.settledCover = settledCover
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
        // A close is anchored to the DEPARTURE post whatever the viewer paged
        // to — which, for a text post opened as a window, has no media. Both specific rects then answer nil and the card
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
    /// Whether the row this close lands on can hold a photograph.
    ///
    /// `heroAppearance` already answers this and says so in its own words: a
    /// TEXT row returns nil, and that is the whole of its transition policy. It
    /// was only ever consulted to BUILD the card, never to decide whether there
    /// should be one — so a viewer who paged onto a photograph and dragged got
    /// a flight whose landing was a row made of words, and watched the card
    /// dissolve away over an empty grey rectangle.
    ///
    /// The landing is always the tapped tile (#1283), so this asks whether
    /// THAT tile can receive a hero: a tile always can; a list's text row
    /// cannot.
    var zoomLandingAcceptsHero: Bool {
        guard let page else { return true }
        let accepts = page.heroAppearance(for: anchorID) != nil
        #if DEBUG
        // Said out loud because a refusal here hands the drag to the OTHER
        // driver, and if that one refuses too the screen leaves on UIKit's own
        // slide with nothing naming the handover that never happened.
        if !accepts, ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f landing REFUSES hero post=%@"
                         + " (row not realized or has no cover)",
                         CACurrentMediaTime(), anchorID.rawValue))
        }
        #endif
        return accepts
    }

    func makeZoomFlightCard() -> any ZoomFlightCard {
        let appearance = page?.heroAppearance(for: anchorID)
        let card = PostGridFlightCard(
            post: page?.post(for: anchorID) ?? Self.placeholder(id: anchorID),
            cover: appearance?.cover,
            style: appearance?.style ?? .tile,
            // A brick's heart is red once the viewer has staked — the card
            // wears what the brick wears.
            viewerStake: page?.viewerStake(on: anchorID) ?? 0
        )
        // A paired (Following) card wears its words as the flight's resting
        // furniture, faded as it grows — the Following row's arrangement
        // (`ForYouRowOrigins.card`). Nil for every other cell.
        // On a CLOSE only — an opening flies the picture alone
        // (`PostGridFlightCard.leaveFurnitureBehind`).
        if !isStagingDismissal {
            card.leaveFurnitureBehind()
        } else if let overlay = page?.restingOverlay(for: anchorID) {
            card.installRestingOverlay(overlay)
        }
        // ⚠️ AND THE PICTURE THE VIEWER IS LEAVING, dissolved into it — the
        // same call `PlaceProfileViewController` makes, for the same reason.
        //
        // DISMISSAL ONLY. On a present the card's own cover IS the departure
        // (the tile the finger is on), so a second operand would blend a
        // picture with itself, which `ExternalHeroZoomSource` records as a
        // defect rather than a no-op.
        //
        // The anchor is the tapped tile (#1283): a close from any other post
        // is exactly the case that needs this.
        if isStagingDismissal, let settled = activePostID(), settled != anchorID {
            landsOnAnotherPost = true
            card.setDeparturePicture(settledCover?())
            // ⚠️ A VIDEO PAGE HAS NO STILL, so `settledCover` is nil there and
            // the card had nothing to blend against: it flew the page's video
            // all the way into the row (#923). The departure it flies IS
            // another post, and saying so lets the row's own picture rise over
            // it.
            card.setDepartureShowsAnotherPost(true)
            // ⚠️ AND THE LANDING'S OWN MOVING PICTURE WHERE THERE IS ONE.
            //
            // The still above is the operand's FLOOR, not the operand: for a
            // landing that is a clip, fading up its thumbnail is precisely the
            // "destination arrives as a thumbnail" this pair exists to remove.
            // Joined by identity to the row's own surface — never by URL, which
            // is the lookup this leg already refuses everywhere else.
            //
            // Nil is an ordinary answer: a landing that is a photograph, or a
            // row whose renderer has never dispatched, keeps the still and the
            // card behaves exactly as it did.
            // Asked for as long as the flight is in the air, because the row may
            // be drawing nothing at take-off — it scrolled out of the autoplay
            // window while the post was open, or never entered one. The first
            // refusal demands a player rather than accepting the still.
            let landingID = anchorID
            //
            // ⚠️ AS LONG AS THE CARD IS IN THE AIR, not for one spring. A grab
            // stages the card at TOUCH-DOWN, and a drag held longer than 0.42s
            // used to land without the landing's picture. The retry still stops
            // the moment the card leaves the tree, so the window is only a
            // ceiling.
            //
            // ⚠️ THE ROW'S PARKED RETURN PLAYER FIRST (#923). The row's own
            // player went with the page at the present and was retired when
            // the viewer paged on, so joining "what the row is drawing" finds
            // nothing; the return player parked at the tap is the row's clip,
            // paused where the viewer left it.
            landingRetry = LandingLiveMediaRetry.arm(
                card: card, window: Self.landingRetryCeiling
            ) { [weak self, weak page] in
                let surface = page?.returnFlightSurface(for: landingID)
                    ?? page?.landingFlightSurface(for: landingID)
                if let surface { self?.landingSurface = surface }
                return surface
            }
        }
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
        // A close from another post that handed the row no clip (its return
        // player was evicted) lands on the row's still: wait for that only.
        page?.isLandingPlaybackReady(
            for: anchorID, expectingVideo: !landsOnAnotherPost || didAdoptLanding
        ) ?? true
    }

    /// Lays the landing tile out before the card is unmounted, so the cell's
    /// subview composition is resolved rather than pending.
    func zoomFinalizeLanding() {
        page?.finalizeLandingLayout(for: anchorID)
    }

    func zoomAdoptLiveMediaView(_ view: UIView) {
        // ⚠️ ON A CLOSE FROM ANOTHER POST THIS IS THE PAGE'S VIDEO, not the
        // row's: adopting it put the post the viewer closed into the row the
        // close came home to (#923). The row takes its own picture instead.
        if landsOnAnotherPost {
            adoptLandingSurface()
            return
        }
        guard let view = view as? VideoRenderView else { return }
        page?.adoptLivePlayback(view, for: anchorID)
    }

    /// Hands the row the clip the card's arriving operand was drawing — once,
    /// from whichever landing hook comes first. A card that flew no departure
    /// surface never calls `zoomAdoptLiveMediaView`, so the source's reveal
    /// calls this too.
    private func adoptLandingSurface() {
        guard landsOnAnotherPost, !didAdoptLanding, let landingSurface else { return }
        didAdoptLanding = page?.adoptLivePlayback(landingSurface, for: anchorID) ?? false
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
            // A caption's emotes play in the frame the card leaves, not a
            // monitor tick later (`EmoteLabel.recheckVisibility`, #922).
            EmoteLabel.recheckVisibility()
            // A completed close from another post (a reversed one conceals
            // instead): the row takes its own clip if no earlier hook did.
            if isStagingDismissal { adoptLandingSurface() }
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
    /// How long a landing picture may be asked for — see the arm above.
    static let landingRetryCeiling: CFTimeInterval = 6

    func zoomSourceDidAbandonDismissal() {
        isStagingDismissal = false
        landingRetry?.cancel()
        landingRetry = nil
        // The post stays open: its row's return player waits, paused, for the
        // next close (#923).
        if landsOnAnotherPost { page?.pauseReturnPlayback(for: anchorID) }
        landsOnAnotherPost = false
        landingSurface = nil
        didAdoptLanding = false
        // The scope the staging pointed at the LANDING row exempts that row
        // from the grid's stops, and the retry may have demanded it a player:
        // it kept playing, hidden under the page, until the final close. The
        // page is staying, so the scope goes back to the post it shows — the
        // one whose player really is the page's.
        if let staying = activePostID() { page?.retargetPlaybackHandoff(to: staying) }
    }

    func zoomSourceWillStageDismissal() {
        // From here on, cards belong to return flights — see `makeZoomFlightCard`.
        isStagingDismissal = true
        // Decided again by the card this staging builds.
        landsOnAnotherPost = false
        landingSurface = nil
        didAdoptLanding = false
        // Pin the grid's inset first, before anything reads a rect from it: the
        // pop animates the safe area, and an unpinned grid keeps drifting under
        // the flight. See `ForYouGridPage.beginHeroFreeze`.
        page?.beginHeroFreeze()
        // ⚠️ HOME TO THE TAPPED TILE, ALWAYS (#1283). The anchor is the
        // departure slot whatever the viewer paged to: nothing in the grid
        // moves to meet the close, and a close from another post crossfades
        // into the tile's own clip (`makeZoomFlightCard`).
        anchorID = departureID
        // ⚠️ AND ONTO THE PAGE THE VIEWER IS ACTUALLY LOOKING AT.
        //
        // The card a close flies carries ONE page of a collection — the one on
        // screen — and the row it lands on keeps whatever page it was left on,
        // which for a row the viewer never touched is the first. So a close
        // from page four landed a photograph of page four onto a row showing
        // page one, and the swap was visible at the exact moment the card was
        // removed. The opening has had this in both directions since
        // `openMediaPage`; the close only ever had it in one.
        //
        // Nil means "not a collection", which is why the row is left alone
        // rather than sent to page zero. Only a close from the SAME post: the
        // page on screen is another post's otherwise, and the tile keeps its own.
        if activePostID() == anchorID, let landed = activeMediaPage?() {
            page?.setMediaPage(landed, for: anchorID)
        }
        // The scope was opened for the TAPPED post; the landing is on this one.
        // Without this the reconcile that fires when the tile is unhidden stops
        // the surface it has just been handed.
        page?.retargetPlaybackHandoff(to: anchorID)
        // ⚠️ THE CARD STAYS, THE MEDIA GOES — on a timeline.
        //
        // `conceals: false` here meant the landing row was fully visible under
        // the incoming card, and for a TILE that is right: concealing a tile
        // hides the whole cell, so the grid would show a hole for the length of
        // the flight.
        //
        // A row is not a tile. Concealing it takes the PREVIEW and leaves the
        // card — its header, caption and counters — which is exactly what the
        // landing wants: the viewer sees the card they are returning to, with a
        // gap where the photograph belongs, and the flying media fills it. With
        // the preview left showing, the same photograph was on screen twice for
        // the whole return, and the card's arrival had nothing to arrive into.
        //
        // Asked of the LANDING POST, not the page: Discover's list holds both,
        // a card's preview and a chunk's tile.
        page?.setHeroHidden(
            true, for: anchorID, conceals: page?.landingConcealsMedia(for: anchorID) == true
        )
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
