import CoreModels
import DesignSystem
import LaunchArguments
import MediaCore
import MediaPlayback
import PostGrid
import PostSurfaces
import ThreadKit
import Transitions
import UIKit

/// What the hero destination asks of its screen (#2387): the pages and their
/// models, the flight's flags, the pager and its locks, the comments it must
/// not close over, and the few hooks a landing runs.
///
/// A view controller: the flight hides, shows and lays out its view.
@MainActor
protocol SnapZoomDestinationHost: UIViewController {
    var collectionView: UICollectionView! { get }
    var orderedIDs: [PostID] { get }
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    var lifecycle: SnapLifecycleDispatcher { get }
    var settledPageIndex: Int { get }
    var activePostID: PostID? { get }
    var activeSnapCell: SnapFeedCell? { get }
    /// Written as well as read: the flight's flags are the destination's to
    /// raise and lower, and the screen's `didSet` still sees every write.
    var flight: SnapFlightPhase { get set }
    var viewModel: FeedViewModel { get }
    var imagePipeline: ImagePipeline { get }
    var stakes: StakeSession? { get }
    var sideList: SnapSideListController? { get }
    var isKeyboardOnScreen: Bool { get }
    /// `SnapVerticalDragRouter`'s owner of a downward drag beginning now.
    var downwardDragOwner: SnapVerticalDragRouter.DownwardOwner { get }
    /// The viewer is on the list's last post, and no page is on its way.
    var isAtEndOfSource: Bool { get }
    var commentsEngagedID: PostID? { get }
    var commentsContentVC: UIViewController? { get }
    var commentsEngagementIsResting: Bool { get }
    var commentsCoordinator: SnapCommentsCoordinator { get }
    /// The one owner of the pager's `isScrollEnabled`.
    var pagerScrollLock: SnapPagerScrollLock { get }
    /// Every page whose media carousel the content freeze holds (#1738).
    var carouselFreeze: CarouselFreezeLedger<SnapFeedCell> { get }
    #if DEBUG
    var authorIdentityView: SnapAuthorIdentityView { get }
    #endif
    func soundFace(for model: FeedItemDisplayModel) -> SnapSoundFace?
    func slotHoldArmsShare(_ model: FeedItemDisplayModel) -> Bool
    func applyPendingComments(animated: Bool)
    func applyGrounds()
    func installAuthorPillAfterLanding()
    func releaseChromeTheme(from nav: UINavigationController?)
}

/// The full-screen feed as a hero's destination (#2387): the flight's
/// replica of the page, the live surface lent to and taken back from the
/// card, the engaged page that stays visible through a grab, the landing,
/// and the gates every dismissal driver asks before it claims a drag.
///
/// ⚠️ NOT THE CONFORMER. The engine casts the SCREEN
/// (`as? any ZoomTransitionDestination`), never this, so
/// `SnapFeedViewController` keeps the conformance and forwards every
/// requirement it answers here, one line each. A requirement it stops
/// forwarding is not a compile error: the protocol's default answers in its
/// place, silently (`SnapZoomForwardingTests`).
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN, as the engine calls it: every entry point
/// runs in the caller's turn, in the order the flight calls the screen.
@MainActor
final class SnapZoomDestination {
    private unowned let host: any SnapZoomDestinationHost

    /// The surface currently on loan to a dismissal's flight card, so a
    /// cancelled grab can take it back.
    var donatedLiveView: VideoRenderView?

    init(host: any SnapZoomDestinationHost) {
        self.host = host
    }

    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect {
        host.view.convert(host.view.bounds, to: container)
    }

    /// How the active page frames its picture (`SnapMediaAspect`) — what a
    /// hero must fly for the page to be its own composition at both ends.
    ///
    /// Nil for a page that FILLS (9:16, 2:3 and taller), for a text page and
    /// for a post with no shape anyone can name, and each nil flies the
    /// page-sized hero this screen always had.
    ///
    /// ⚠️ THE CURRENT PAGE'S PICTURE, AS DRAWN, whenever the page can say: a
    /// collection's pages need not agree about their shape, and a dismissal
    /// leaves from whichever the viewer is on. The page's own framing and its
    /// own backdrop are handed over as they are, so the flight's window and the
    /// page are the same pixels at the hand-over. Before the page has a
    /// picture (a cold open), the model's DECLARED shape decides, and the
    /// flying card's own still — the tile's cover, the same picture — makes
    /// the backdrop until the page renders its own. Its SHAPE is never used:
    /// see the note where the declared shape is read.
    func zoomPageFraming(sourcePicture: UIImage?) -> ZoomPageFraming? {
        let index = host.lifecycle.activeIndex ?? host.settledPageIndex
        guard host.orderedIDs.indices.contains(index),
              let model = host.modelsByID[host.orderedIDs[index]], model.mediaURL != nil
        else { return nil }
        let cell = host.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SnapFeedCell
        let drawn = cell?.pictureFraming
        let framing: MediaFraming
        let aspect: CGSize
        if let drawn, let measured = drawn.aspect {
            framing = drawn.framing
            aspect = measured
        } else {
            let declared: CGSize? = {
                let pages = model.mediaPages
                if let page = cell?.currentMediaPage, pages.indices.contains(page), page > 0 {
                    return CGSize(width: pages[page].aspectRatio, height: 1)
                }
                return model.headAspectRatio.map { CGSize(width: $0, height: 1) }
            }()
            // ⚠️ NOT the source picture's size: a tile's cover is a thumbnail,
            // and thumbnails are cropped (168×168 squares for 9:16 clips in
            // the mock corpus). No shape anyone can vouch for flies the
            // filling hero, which is at worst the flight that always existed.
            guard let shape = declared else { return nil }
            framing = SnapMediaAspect.presentation(for: shape)
            aspect = shape
        }
        switch framing {
        case .fill:
            return nil
        case .fitBlack:
            return ZoomPageFraming(mediaAspect: aspect, backdrop: .black)
        case .fitBlurred:
            let backdrop = drawn?.backdrop ?? sourcePicture.flatMap(MediaBackdrop.blurred)
            return ZoomPageFraming(
                mediaAspect: aspect, backdrop: backdrop.map { .picture($0) } ?? .black
            )
        }
    }

    /// A fresh inert replica of the active page's chrome for the flying card —
    /// page content only (scrim, caption); the navigation bar stays real
    /// and static above the flight. Configured now if the post is already
    /// loaded; otherwise `render(_:)` fills it in when the data lands
    /// mid-flight — the scaffold's geometry is data-independent, so late text
    /// never moves anything.
    func zoomFlightChrome() -> UIView? {
        // A TEXT page has no resting chrome to replicate, because it is never
        // at rest: it mounts its comment layout on `willDisplay` and stays
        // there (`presentRestingComments`). The replica below is configured at
        // REST, so a text post's flight crossfaded INTO the media layout —
        // rail, subtitle zone, the empty media card — and the comment layout
        // only appeared when the card was removed. That is the reported "wrong
        // mode for the whole flight, snapping at the last frame", and it is
        // the replica's doing: the destination itself is already engaged
        // before the push (`destinationEngaged=true` at flight-build time).
        //
        // ⚠️ AN ENGAGED PAGE GETS NO REPLICA, and the reason is written out in
        // `RevealTransition` — which is where this should have been read first.
        //
        // A post opened from its COMMENT COUNT engages before the push. The
        // replica, built from the RESTING arrangement, then flew the caption,
        // the rail and the page dots for the whole flight and swapped to the
        // thread as the card was removed: half a second of the layout the
        // viewer had chosen not to open.
        //
        // ❌ A STILL OF THE ENGAGED PAGE was tried in its place and is reverted.
        // It is the sixth instance of a mistake this codebase has already
        // catalogued: "every previous attempt at a text hero flew a replica of
        // the row and made it impersonate the destination, and all five of them
        // died of the same thing — a text page IS its comment stream, a hosted
        // child controller with its own self-sizing layout, and no stand-in can
        // be that. The artifacts were the symptoms (A SKELETON IN THE
        // PHOTOGRAPHED STILL, a blank card, the wrong safe area, two captions);
        // impersonation was the disease."
        //
        // Every one of those symptoms turned up again, in order: the caption's
        // glass missing because a lens has nothing to sample when detached,
        // then the whole panel frozen mid-skeleton on two runs in three,
        // because the still races a fetch it cannot outrun. A still that shows
        // the WRONG content is worse than a landing that is merely late.
        //
        // What the text page does instead is show the REAL page through a
        // mask that opens from the row's rect. That is the shape of the answer
        // here too, and it is not a line of code — see the notes on this
        // commit.
        // A spare when one is ready (#2126): this runs in the tap's turn.
        let chrome = SnapChromeView.make()
        chrome.isUserInteractionEnabled = false
        chrome.markAsFlightReplica()
        // Captured, not ambient: the replica must render at the live cell's
        // exact insets even though it lives in the transition container.
        chrome.setFixedInsets(host.view.safeAreaInsets)
        configureFlightChrome(chrome)
        host.flight.flightChrome = chrome
        return chrome
    }

    /// The feed has something to show once it has pages. Pushed cold it has
    /// none until its first `render`, which under injected latency arrived
    /// 2.18s after the flight began — against a 0.42s flight, so the card was
    /// removed over an empty screen and the cell's black floor was what showed.
    var zoomDestinationContentIsReady: Bool { !host.orderedIDs.isEmpty }

    /// The render half of landing readiness: the active page's media area is
    /// compositing something (surface or poster). Nil cell — not realized
    /// yet — reports true and falls back to the data-only behaviour.
    var zoomDestinationMediaIsRendering: Bool {
        let cell = host.activeSnapCell
        let rendering = cell?.isMediaContentRendering ?? true
        #if DEBUG
        // Why a landing is being held, in the surface's own words — a "no"
        // with every component healthy has already cost one wrong deduction.
        if !rendering, LaunchArgument.zoomLiveLog.isPassed() {
            print(String(format: "[zoom-live] %.3f landing NOT rendering: %@",
                         CACurrentMediaTime(), cell?.debugMediaState ?? "no active cell"))
        }
        #endif
        return rendering
    }

    /// The seam's name for `prepareForHeroPresentation`, so a presenter that
    /// holds this screen as `any ZoomTransitionDestination` — which the map
    /// does, since Maps depends on FeedInterface rather than Feed and cannot
    /// name this type — can pre-pay the same layout For You pre-pays.
    func zoomPrepareForPresentation(in bounds: CGRect) {
        prepareForHeroPresentation(in: bounds)
    }

    /// Pays this page's first LAYOUT and RASTER before the flight instead of
    /// inside it.
    ///
    /// The hero transition's build lays the destination out (`container
    /// .layoutIfNeeded`), and the commit that follows draws its layer tree for
    /// the first time — text, the rail's bubbles, the media card. Measured on
    /// the present leg: ~55ms of build plus ~100ms before the first frame is
    /// delivered, against ~50ms post-build on the dismiss leg, which flies
    /// home to a grid already drawn. That difference is this page's first
    /// raster, and while the card is flying it is a visible pause.
    ///
    /// It cannot be avoided — the pixels have to be produced once — but it can
    /// be paid while NOTHING IS MOVING. Called just before the push, it lands
    /// in the same frame as the tap, where a dropped frame costs nothing,
    /// rather than in the first frames of the animation.
    ///
    /// `CATransaction.flush()` is the part that matters: `layoutIfNeeded`
    /// settles geometry but does not draw, and `display()` is driven by a
    /// commit. Flushing forces that commit now.
    func prepareForHeroPresentation(in bounds: CGRect) {
        host.view.frame = bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // The flush is cheap insurance rather than the mechanism: measured, it
        // is the LAYOUT above that moves (build 54-75ms → 22ms). Parking the
        // tree in the render hierarchy for one flush — so `display()` actually
        // runs on it — was tried and measured identical, so the destination's
        // view hierarchy is left alone.
        CATransaction.flush()
        // NOT here: pre-sizing the BAR's custom views. Bar items live on the
        // navigation bar rather than in this view, so they are first measured
        // inside `-[UINavigationBar _setItems:transition:]` — synchronously in
        // the push, inside the flight's stack — which makes them look like the
        // obvious next thing to pre-pay. Measured: laying them out and asking
        // for their fitting size here left the stall unchanged (91-101 ms vs
        // 85-108 ms) and added ~7 ms to the build. Their cost is not the
        // MEASURING; it is iOS 26 materialising each platter's glass once the
        // view is inside the bar's own effect host, which nothing outside the
        // bar can trigger early. See `ZoomFlightProfiler` for the sampled
        // attribution.
    }

    /// Hides only the feed's own view: the navigation bar above it (owned by
    /// the wrapping navigation controller) keeps rendering natively while the
    /// flying card impersonates the page underneath it.
    func setZoomContentHidden(_ hidden: Bool) {
        // ⚠️ A MASKED-HERO OPENING STAYS VISIBLE, and that inversion is the
        // whole of option B. The flight hides the destination because the card
        // is its stand-in; here the destination is NOT being stood in for — the
        // real thread is what the window shows, drawn over the card carrying
        // the photograph. Hiding it would leave the window empty.
        //
        // ⚠️ AND THE WINDOW OPENS FROM HERE, not from `zoomTransitionWillBegin`.
        // That hook runs in the transition controller's `init`, BEFORE the push
        // — deliberately, so playback can be suppressed early enough — which is
        // before this screen has laid out or realized the page it is about to
        // show. Asked there, it had no active cell to mask and silently did
        // nothing: the flight carried the photograph correctly and the thread
        // still arrived in one frame at the landing.
        // ⚠️ ON EVERY OPENING, not just the masked one: this is the last seam
        // before the card covers the screen, and the first where the page is
        // real. A request that could not be honoured before the push is
        // honoured here, unanimated, so the post still LANDS in its thread
        // rather than rearranging itself afterwards.
        //
        // The second attempt at the engagement, and for a cold open it is the
        // one that works: by here the destination is in the container at its
        // real size, so the page it is about to show is realized. A no-op
        // when the pre-push attempt already succeeded.
        if hidden { host.applyPendingComments(animated: false) }
        // ⚠️ AN ARMED GRAB REFUSES THE HIDE, and refusing it once is not enough.
        //
        // The hide does not run at the grab's start: it is deferred by a commit
        // and a display tick, so it lands AFTER the first pan events. Arming
        // the dismissal set the page visible once and the hide then arrived and
        // won, which is "the thread disappears the instant I grab" exactly.
        // Declining here is what makes the visibility hold for the length of
        // the gesture.
        guard !host.flight.isEngagedDismissalActive else {
            return host.view.alpha = 1
        }
        host.view.alpha = hidden ? 0 : 1
    }

    /// ⚠️ EVERY GRAB MOVES THE LIVE PAGE (#1915, the owner 2026-10-29, after
    /// filming Instagram, TikTok and Douyin): the page itself follows the
    /// card, its whole interface on it and alive — the streams, the ticker,
    /// the wheel, the disc. No replica stands in for it, so nothing on the
    /// page is stilled for the grab (`FlightActivity`).
    var zoomGrabCarriesLiveInterface: Bool { host.activeSnapCell != nil }

    /// ⚠️ AN ENGAGED PAGE STAYS VISIBLE THROUGH A DISMISSING GRAB, for the same
    /// reason it does through the opening: the card impersonates the page's
    /// MEDIA, and a thread is not media. Hidden with everything else it
    /// vanished on the grab's second tick, and the viewer pulled a photograph
    /// home from a screen that had already stopped showing what they were
    /// reading.
    ///
    /// ⚠️ ARMED FROM HERE, not from `setZoomContentHidden`, and the difference
    /// is a whole dismissal. Both routes home hide the content — the grab and
    /// the back button — but only the grab drives a progress channel. Arming on
    /// the hide left a back-button dismissal showing a full-screen thread over
    /// a card flying away underneath it, with nothing to ever take it down.
    /// This method is the grab's alone, so it is the honest signal that one is
    /// running.
    func setZoomDismissState(_ state: ZoomDismissState) {
        guard let cell = host.activeSnapCell else { return }
        if !host.flight.isEngagedDismissalActive {
            host.flight.isEngagedDismissalActive = true
            host.view.alpha = 1
            // The floors between the page and the card go transparent — the
            // page itself stays whole, so what shows around it as it shrinks is
            // the flight, not this screen's black.
            host.view.backgroundColor = .clear
            host.collectionView.backgroundColor = .clear
            cell.beginLiveGrab()
            // The card's replica of the interface would draw it a second
            // time under the live page: the page is the one copy.
            host.flight.flightChrome?.isHidden = true
        }
        // Re-asserted every event, not just at arming: anything that hides the
        // page mid-grab is undone on the next frame the finger produces, so a
        // race can cost one frame instead of the whole gesture.
        host.view.alpha = 1
        // ⚠️ THE NAVIGATION BAR IS NOT FADED HERE, and it used to be:
        // `alpha = 1 - progress` on every pan event, because a bar pinned to
        // the screen's corners over a VISIBLE, travelling page reads as two
        // layers coming apart. Native chrome is UIKit's (see
        // `TabBarRevealPolicy`): the pop's own navigation-bar transition takes
        // the engaged interface's items away, on UIKit's clock.
        // The rect arrives in the CONTAINER's coordinates, which are this
        // view's: both are full-bleed in it. The same assumption the opening
        // makes about the rect it is handed.
        cell.setEngagedDismissal(state.with(card: host.view.convert(state.card, to: cell.contentView)))
    }

    /// Puts the page back together after a grab, committed or abandoned. Safe
    /// to call when no grab ran: the flag is the whole guard.
    private func endEngagedDismissalIfNeeded() {
        guard host.flight.isEngagedDismissalActive else { return }
        host.flight.isEngagedDismissalActive = false
        host.activeSnapCell?.endEngagedDismissal()
        // Through the resolver: this used to hand back a literal black, which
        // re-blacked a TEXT page even with its data present.
        host.applyGrounds()
    }

    /// A presenting flight is staging. The active page must not start its own
    /// playback while the card is flying THAT PLAYER, so the flag is set before
    /// this controller lays out and activates anything.
    ///
    /// ⚠️ CONDITIONAL SINCE THE MAP LEARNED TO FLY SPRITE SHEETS. The deferral
    /// used to be unconditional, which is right for every flight that leaves a
    /// grid tile: the tile and this page share one pooled player (same asset,
    /// same post-id scope), so a start here attaches a newer layer and blanks
    /// the card. A marker flying a baked sheet shares nothing — its post has no
    /// player anywhere yet — and deferring only bought the viewer a beat of
    /// poster-then-black at the landing. The source says which flight this is.
    func zoomTransitionWillBegin(flyingLivePlayer: Bool) {
        host.flight.isAwaitingZoomPresentation = true
        // A start position belongs to ONE flight: this one tells its own, after
        // this, or none (#625).
        host.flight.flightMediaStart = nil
        host.flight.flightCarriesActivePlayer = flyingLivePlayer
        host.activeSnapCell?.defersPlaybackForFlight = host.flight.defersPlaybackForStagingFlight
        // Reaches a cell only when this screen is being re-presented over a
        // page it already holds; the first present stamps both flags on the
        // cell as it is realised (`apply` / `willDisplay`).
        host.activeSnapCell?.setChromeHeldForFlight(true)
        #if DEBUG
        if LaunchArgument.zoomLiveLog.isPassed() {
            // Read against `[page-play] start` and the landing below: a start
            // BETWEEN these two lines is the page decoding during the flight.
            print(String(format: "[zoom-live] %.3f willBegin flyingPlayer=%@ defers=%@",
                         CACurrentMediaTime(), flyingLivePlayer ? "Y" : "N",
                         host.flight.defersPlaybackForStagingFlight ? "Y" : "N"))
        }
        #endif
    }

    /// The clip time the presenting flight's picture shows (#625), for the
    /// page it opens on. Handed to that page's cell as it is realised and
    /// spent by its first start.
    ///
    /// ⚠️ A COLD OPEN HAS NO POST YET. The feed is pushed before its posts
    /// arrive, so `activePostID` is nil at take-off and the time used to be
    /// dropped — the page started at zero on exactly the opens whose first frame
    /// is late (#633). It is kept for the entry page instead: the first page
    /// `activePostID` names once it can, by the same fallback rule.
    func zoomTransitionWillStartMedia(at seconds: TimeInterval) {
        host.flight.flightMediaStart = (host.activePostID, seconds)
        if let cell = host.activeSnapCell { stampFlightMediaStart(on: cell) }
    }

    /// Gives the entry page its start position — once, and only to the page
    /// showing the post the flight carried.
    func stampFlightMediaStart(on cell: SnapFeedCell) {
        guard let start = host.flight.flightMediaStart,
              let shown = cell.representedPostID,
              Self.isFlightEntryPage(shown, carried: start.postID, entry: host.activePostID)
        else { return }
        cell.flightMediaStartTime = start.seconds
        host.flight.flightMediaStart = nil
    }

    /// Whether the page showing `shown` is the one a flight's start position is
    /// for: the post the flight named, or — when it took off before the feed
    /// had posts — the entry page. Pure, for tests.
    static func isFlightEntryPage(_ shown: PostID, carried: PostID?, entry: PostID?) -> Bool {
        if let carried { return shown == carried }
        return shown == entry
    }

    /// Parks the active page's player for the source it is flying home to.
    @discardableResult
    func zoomParkLiveMediaForHandoff() -> Bool {
        // Already handed over as a donated view, which parks as part of the
        // same step — parking again would retire the player the card is flying.
        guard donatedLiveView == nil else { return true }
        return host.activeSnapCell?.parkPlayback() ?? false
    }

    /// Hands the active page's rendering surface to a dismissal's flight card.
    ///
    /// ⚠️ A DISMISSAL's. Refused while a present is staging, and that guard is
    /// the whole of a defect.
    ///
    /// `ZoomFlight.build` asks the destination when the source declines, on the
    /// stated assumption that "on a present the destination's page isn't playing
    /// yet and refuses". That held while a post's playback was decided by its
    /// head attachment — a freshly configured page had nothing running.
    ///
    /// A mixed carousel broke it. This controller is REUSED: on a second
    /// present its active cell is still the previous visit's, its carousel is
    /// still on the page that visit left, and its clip is still held — paused
    /// in place, which is deliberate. So it answered yes, and the flight from a
    /// card showing a PHOTOGRAPH carried the video of a page nobody was looking
    /// at. Measured: `source attach surface -> false` (the card correctly
    /// declined) followed by a card reporting `frames=2`.
    func zoomDonateLiveMediaView() -> UIView? {
        guard !host.flight.isAwaitingZoomPresentation else { return nil }
        guard let donated = host.activeSnapCell?.donateLiveRenderView() else { return nil }
        donatedLiveView = donated
        return donated
    }

    /// Takes the card's live surface at landing, so the page renders the frame
    /// the card was showing rather than starting a layer of its own.
    func zoomAdoptLiveMediaView(_ view: UIView) {
        guard let view = view as? VideoRenderView else { return }
        donatedLiveView = nil
        // The page warmed its OWN layer during the flight, so landing is a
        // visibility flip and the card's surface is simply discarded. Only fall
        // back to taking the card's view when there was nothing to warm.
        if host.activeSnapCell?.revealWarmAttachedSurface() == true { return }
        host.activeSnapCell?.adoptLiveRenderView(view)
    }

    /// Puts a donated surface back — the abandoned grab, where this page stays
    /// on screen and has to look untouched.
    func zoomReclaimLiveMediaView(_ view: UIView) {
        guard let view = view as? VideoRenderView else { return }
        donatedLiveView = nil
        host.activeSnapCell?.reclaimDonatedPlayback(view)
    }

    func zoomTransitionWillDepart() {
        host.flight.isDepartingWithFlight = true
    }

    func zoomTransitionDidEnd() {
        #if DEBUG
        if LaunchArgument.zoomProfile.isPassed() {
            print("[feed-reuse] LANDED showing \(host.activePostID?.rawValue ?? "nil")"
                  + " of \(host.orderedIDs.prefix(3).map(\.rawValue))")
        }
        #endif
        #if DEBUG
        if LaunchArgument.zoomLiveLog.isPassed() {
            print(String(format: "[zoom-live] %.3f landed", CACurrentMediaTime()))
        }
        #endif
        #if DEBUG
        // `-landing-probe`: the replica's caption against the page's, in
        // window space, at the instant one fades into the other. A delta here
        // is the "small jump at the end of the hero" a device shows.
        if LaunchArgument.landingProbe.isPassed(),
           let window = host.view.window, let replica = host.flight.flightChrome,
           let page = host.activeSnapCell?.debugChrome {
            let a = replica.debugCaptionFrame(in: window), b = page.debugCaptionFrame(in: window)
            print(String(format: "[landing-probe] replica caption y=%.1f h=%.1f w=%.1f | page caption y=%.1f h=%.1f w=%.1f",
                         a.minY, a.height, a.width, b.minY, b.height, b.width)
                  + " | insets page=\(host.activeSnapCell?.debugChromeInsets ?? .zero) replica=\(replica.layoutMargins)")
        }
        #endif
        #if DEBUG
        if LaunchArgument.pillProbe.isPassed() {
            host.authorIdentityView.debugProbe("landed")
            for delay in [0.016, 0.05, 0.1, 0.2, 0.4, 0.8, 1.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.host.authorIdentityView.debugProbe("landed+\(delay)")
                }
            }
        }
        #endif
        host.flight.flightChrome = nil
        host.flight.isAwaitingZoomPresentation = false
        host.installAuthorPillAfterLanding()
        // Back to the conservative reading for whatever presents next: this
        // controller outlives the flight that set it.
        host.flight.flightCarriesActivePlayer = true
        // The replica is gone; the page's own chrome comes in rather than
        // simply stopping being covered.
        host.activeSnapCell?.setChromeHeldForFlight(false)
        // A flight card may have mirrored the active cell's player; with the
        // card gone, the cell reclaims the render slot (only the most
        // recently attached layer of a shared player is guaranteed to
        // display). Harmless when nothing was mirrored.
        //
        // ⚠️ NOT FOR A PAGE THAT LEAVES WITH THE FLIGHT
        // (`zoomTransitionWillDepart`). Reclaiming rebound the player to this
        // hidden page right after the landing tile adopted it, and the
        // deferred start below played a clip on a screen being removed. A
        // departing page only lets go, so the next visit starts clean.
        let departing = host.flight.isDepartingWithFlight
        host.flight.isDepartingWithFlight = false
        if departing {
            host.activeSnapCell?.releasePlaybackForDeparture()
            // ⚠️ AND THE SHARED BARS' STYLE (hero audit 2.16). `viewWillAppear`
            // lends the stack's navigation bar, toolbar and glass host this
            // page's style (dark over media); `viewWillDisappear` hands it
            // back. A push caught and thrown back never reaches the second:
            // the presenter's header stayed in the feed's dark style over its
            // own light content — glass gone grey, icons thin — until the next
            // visit. Idempotent after an ordinary pop, which already did it.
            host.releaseChromeTheme(from: nil)
        } else {
            host.activeSnapCell?.reclaimPlayback()
            // And the presenting leg's held-back start runs now: the card is
            // gone, so attaching here is the hand-off rather than a theft.
            // Adopts the parked player, so the page resumes instead of
            // restarting.
            host.activeSnapCell?.startDeferredPlayback()
        }
        // The comments warm was held back across the flight (see
        // `prewarmComments`) — and it does NOT resume here, because "landed"
        // is not yet "idle". Measured: run at this instant it produced a
        // 156ms stall at +776ms from the flight's start, against ~33ms
        // without it. That is the flight's stall moved rather than removed:
        // off the card, but still inside the settle a viewer is watching.
        host.commentsCoordinator.scheduleIdleCommentsWarm()
        // …unless a card asked to land IN the comments, in which case there is
        // nothing to warm for: the engagement is happening now.
        host.applyPendingComments(animated: true)
        endEngagedDismissalIfNeeded()
    }

    /// The hero transition's dismiss-leg live seam: mirrors the active cell's
    /// playing video onto the flight card's render surface, so the card flies
    /// the same frames the page was showing instead of a frozen cover.
    func zoomMirrorLiveMedia(onto surface: UIView) -> Bool {
        guard let renderView = surface as? VideoRenderView,
              let cell = host.activeSnapCell else {
            #if DEBUG
            if LaunchArgument.zoomLiveLog.isPassed() {
                print("[zoom-live] destination mirror refused: activeCell=\(host.activeSnapCell != nil)")
            }
            #endif
            return false
        }
        let mirrored = cell.mirrorPlayback(to: renderView)
        #if DEBUG
        if LaunchArgument.zoomLiveLog.isPassed() {
            print("[zoom-live] destination mirror -> \(mirrored)")
        }
        #endif
        return mirrored
    }

    /// Configures the replica from the page the card flies to/from: the active
    /// page if one is settled, else the first post (a map tap's feed opens on
    /// its tapped post). No-op until that model exists.
    func configureFlightChrome(_ chrome: SnapChromeView) {
        let index = host.lifecycle.activeIndex ?? 0
        guard host.orderedIDs.indices.contains(index),
              let model = host.modelsByID[host.orderedIDs[index]] else { return }
        chrome.configure(with: model)
        chrome.setPostLikeCount(host.viewModel.visibleLikeCount(for: model))
        chrome.setImagePipeline(host.imagePipeline)
        // ⚠️ THE REPLICA CARRIES EVERYTHING THE PAGE'S CHROME WILL SHOW AT
        // LANDING (charter P9). It used to carry the caption and the author
        // alone: the page bar, the subtitle pill and the ticker's band then
        // appeared all at once when the page's own chrome faded in, and the
        // caption jumped with them (filmed on a device, 25 September 2026).
        // Same page count, same streams — whatever the cache already holds —
        // so the fade at landing swaps two identical pictures.
        if model.isCollection {
            chrome.setMediaPageCount(
                model.mediaPages.count,
                current: host.activeSnapCell?.currentMediaPage ?? 0,
                clipPages: Set(model.mediaPages.enumerated().filter { $0.element.videoURL != nil }.map(\.offset))
            )
        } else if model.mediaKind == .video, model.mediaURL != nil {
            chrome.setMediaPageCount(1, current: 0, clipPages: [0])
        }
        chrome.updateCommentStreams(host.viewModel.commentStreams(for: model.id))
        // ⚠️ AND THE PILL SHOWS ITS FIRST CUE (#2002): a replica's zone used
        // to stay down, never activated, and the pill faded in after the
        // landing. Active, it presents the warmed first cue INSTANTLY, with
        // its count bubble, as the page under it does; the page then keeps
        // it at the landing (`SnapSubtitleView.replayEntrance`).
        chrome.setSubtitlesActive(true)
        // And the sound bubble, so it flies in with the page rather than
        // appearing at the landing (#683).
        chrome.setSoundFace(host.soundFace(for: model))
        // …or the post's Share, a pushed text page's (#1999).
        chrome.setSlotSharesPost(true, holdArmsShare: host.slotHoldArmsShare(model))
        // The replica's boost anchor wears the same face as the live one —
        // a boosted post must not flash back to the glyph mid-flight.
        chrome.setBoostTotal(host.stakes?.total(on: model.id) ?? 0)
        #if DEBUG
        if LaunchArgument.zoomProfile.isPassed() {
            print("[flight-chrome] \(model.id.rawValue) hasMedia=\(model.mediaURL != nil)"
                  + " destinationEngaged=\(host.activeSnapCell?.isCommentsEngaged.description ?? "no cell")"
                  + " engagedID=\(host.commentsEngagedID?.rawValue ?? "nil")")
        }
        #endif
    }

    /// A grab may begin from any page — but not mid-fling, where the user's
    /// intent is still vertical and freezing the pager would strand it
    /// between pages.
    ///
    /// Never while the side list is open or moving (#1425): a rightward drag
    /// then closes the list, and the screen stays.
    var isReadyForInteractiveDismissal: Bool {
        !host.collectionView.isDecelerating && !(host.sideList?.isEngaged ?? false)
    }

    /// ⚠️ THE POST ON SCREEN RIGHT NOW, not the one that opened this screen.
    ///
    /// A text page has no media to fly, so it goes home as a card; anything
    /// with a picture flies that picture. The distinction used to be settled at
    /// the tap, which is correct for a screen that shows one post and wrong for
    /// a PAGER — swipe from a photograph to a text post and the driver chosen
    /// at the tap is the wrong one for the post being dismissed.
    ///
    /// Read from the MODEL rather than from the realized cell: a grab can begin
    /// on a page whose cell is mid-recycle, and the answer must not depend on
    /// what happens to be dequeued. Falls back to `.hero`, the historical
    /// answer, when there is no model to ask.
    var zoomDismissalKind: ZoomDismissalKind {
        // The SETTLED page, not the active one — see `settledPageIndex`. A pop
        // takes the screen's visibility away before it asks this.
        let index = host.settledPageIndex
        guard host.orderedIDs.indices.contains(index),
              let model = host.modelsByID[host.orderedIDs[index]]
        else { return .hero }
        return model.mediaURL == nil ? .card : .hero
    }

    /// The vertical grab's extra gate (the horizontal one needs none: the
    /// pager owns no horizontal gestures). Refused while a comments panel is
    /// OPEN — the engaged layer owns the whole vertical axis (page drive,
    /// pull-dismiss), so a downward drag there is never a dismissal. A
    /// RESTING engagement is a text page's ordinary layout, not an open
    /// panel, and stays grabbable — with one nuance below. Also refused over
    /// territory that owns its own vertical gestures (the shortcut rail's
    /// column, the composer).
    func zoomVerticalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        // ⚠️ THE FIRST POST'S, ONLY (#2057, the owner 2026-11-02): on a later
        // post the downward drag is the pager's — the previous post comes in.
        // The router the pager asks too, so exactly one of them claims it.
        guard host.downwardDragOwner == .dismissal else { return false }
        return verticalCloseTerritoryPermits(at: location, in: view)
    }

    /// What lies under the finger, for a downward close — the keyboard, an
    /// open panel, the rail and the composer refuse; a resting stream yields
    /// at its top. The upward close (`zoomUpwardDismissalPermitted`) reads
    /// the same tenants, mirrored.
    func verticalCloseTerritoryPermits(at location: CGPoint, in view: UIView) -> Bool {
        // ⚠️ AN OPEN KEYBOARD OWNS THE DOWNWARD DRAG.
        //
        // The comments list dismisses the keyboard interactively — drag down
        // over it and the keyboard follows the finger. That gesture and this
        // one are the same drag in the same direction, and the keyboard's is
        // the one the viewer means: they are looking at a keyboard they want
        // gone, not at a post they want closed. Claiming it here closed the
        // post out from under a half-typed comment.
        //
        // Only while the keyboard is actually up, so nothing changes for the
        // rest of the page's life.
        guard !host.isKeyboardOnScreen else { return false }
        let point = host.collectionView.convert(location, from: view)
        guard let hit = host.collectionView.hitTest(point, with: nil) else { return true }
        for current in sequence(first: hit, next: { $0.superview }) {
            if current is SnapShortcutRailView || current is SnapWheelGlassView || current is SnapRailBoostButton
                || current is CommentsInputBar {
                return false
            }
            if current is SnapCommentsContainerView {
                // A RESTING text page's whole body is this container, which
                // would put the vertical dismissal out of reach on exactly
                // the pages that have no other downward verb. The sheet
                // idiom resolves it: at the stream's TOP a downward drag has
                // nothing left to scroll, so the territory yields to the
                // dismissal precisely there — mid-stream it keeps scrolling,
                // and an OPEN panel never reaches this line (the guard
                // above).
                let stream = host.commentsContentVC as? PostDetailViewController
                return host.commentsEngagementIsResting && stream?.streamIsAtTop == true
            }
        }
        return true
    }

    /// The UPWARD grab's gate (#628): a swipe up past the very end closes the
    /// feed — the window follows the finger up — and nowhere else.
    ///
    /// The vertical gate's rules, mirrored: refused while the keyboard is up
    /// or a comments panel is OPEN, refused over the rail and the composer,
    /// and on a RESTING text page the stream yields only at its BOTTOM (where
    /// the downward grab needs its top). And first of all: only at the end of
    /// a finished source, and never mid-fling (`isReadyForInteractiveDismissal`
    /// is asked separately, as for every axis).
    ///
    /// The pager declines the same touch (`SnapFeedCollectionView`), so
    /// exactly one side claims an upward drag — the split the downward
    /// direction already keeps.
    func zoomUpwardDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        #if DEBUG
        // `-grab-log`: why an upward swipe at the end did or did not close.
        if LaunchArgument.grabLog.isPassed() {
            print("[grab-up] loading=\(host.viewModel.isLoadingNextPage) page=\(host.settledPageIndex)/\(host.orderedIDs.count)"
                + " keyboard=\(host.isKeyboardOnScreen) engaged=\(host.commentsEngagedID?.rawValue ?? "nil")"
                + " resting=\(host.commentsEngagementIsResting)"
                + " streamAtBottom=\((host.commentsContentVC as? PostDetailViewController)?.streamIsAtBottom.description ?? "-")")
        }
        #endif
        guard host.isAtEndOfSource, !host.isKeyboardOnScreen else { return false }
        let point = host.collectionView.convert(location, from: view)
        guard let hit = host.collectionView.hitTest(point, with: nil) else { return true }
        let inPageDriveBand = host.commentsEngagedID != nil && host.commentsCoordinator.engagedCell().map { cell in
            cell.cardSwipeRegionContains(cell.contentView.convert(point, from: host.collectionView))
        } == true
        switch Self.upwardCloseTerritory(from: hit, inPageDriveBand: inPageDriveBand) {
        case .refuses:
            return false
        case .closes:
            return true
        case .streamDecides:
            let stream = host.commentsContentVC as? PostDetailViewController
            return host.commentsEngagementIsResting && stream?.streamIsAtBottom == true
        }
    }

    enum UpwardCloseTerritory: Equatable {
        case refuses, closes, streamDecides
    }

    /// Who an upward drag at the list's end belongs to, by where it landed.
    /// Pure walk-up, for tests.
    ///
    /// ⚠️ THE PAGE DRIVE'S TERRITORY CLOSES (#770). On an engaged text page the
    /// pager is disabled; the only drags that page are the composer bar's and
    /// the header band's, which hand-move the pager (`drivePageSwipe`). At the
    /// last post that drive has nowhere to go: refused here, the drag lifted
    /// the whole page and dropped it back, and the feed never closed (filmed
    /// on a device, the last card of For You's Following rail). There the
    /// close takes it, and the drive stands down (`pageDriveYieldsToClose`).
    ///
    /// The rail keeps its own drags; the stream below the band yields only
    /// at its bottom — the downward grab's rule, mirrored.
    static func upwardCloseTerritory(from hit: UIView, inPageDriveBand: Bool) -> UpwardCloseTerritory {
        for current in sequence(first: hit, next: { $0.superview }) {
            if current is SnapShortcutRailView || current is SnapWheelGlassView || current is SnapRailBoostButton { return .refuses }
            if current is CommentsInputBar { return .closes }
            if current is SnapCommentsContainerView { return inPageDriveBand ? .closes : .streamDecides }
        }
        return .closes
    }

    /// The horizontal grab's gate, which exists because a post's media can now
    /// be a carousel.
    ///
    /// Three answers, in order:
    ///
    /// 1. **From the screen's leading edge, always yes.** That strip is the
    ///    system's back gesture and the viewer's muscle memory; a carousel
    ///    borrowing it would make the one gesture that always means "back" mean
    ///    something else on exactly the screens that are hardest to leave.
    /// 2. **On a carousel that has somewhere to go back to, no.** A rightward
    ///    drag there means "previous photo". The carousel is the tenant and it
    ///    wins its own territory.
    /// 3. **On the FIRST page, yes.** The carousel has nothing to the left, so
    ///    holding the gesture would spend it on a rubber-band. It passes
    ///    straight through — which is also what makes leaving a gallery feel
    ///    like leaving anything else once you have paged back to the start.
    ///
    /// ⚠️ Answers 2 and 3 are `MediaCarouselTouchRouting`'s, not this screen's.
    /// The walk down to the carousel under the touch was written here first and
    /// the next screen with a gallery on it was about to copy it — the twin-pager
    /// mistake, a third time. And this gate is only ever HALF the answer: it says
    /// the dismissal MAY claim the drag, and the carousel's own scroll view has
    /// to give it up as well, which it does in `yieldsRightwardDrag`.
    func zoomHorizontalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        if location.x - view.bounds.minX <= Self.backEdgeZone { return true }
        // ⚠️ `-1`, because the drag is RIGHTWARD and pages run the other way to
        // the finger. Rightward is the only horizontal direction this gate is
        // ever asked about — `ZoomDismissAxis.match` demands `velocity.x > 0`
        // before anyone reaches here — so the mirror case is not this screen's
        // to answer; see `MediaCarouselView.yieldsRightwardDrag`.
        return MediaCarouselTouchRouting.dragPassesThroughCarousel(
            at: host.collectionView.convert(location, from: view),
            in: host.collectionView, towardsPageDelta: -1
        )
    }

    /// The system's back-gesture strip. Matched to `HorizontalPagerScrollView`'s
    /// own, which yields the same zone to the same gesture for the same reason.
    private static var backEdgeZone: CGFloat { PagedScreenDismissalPolicy.edgeZone }

    func setContentScrollEnabled(_ enabled: Bool) {
        // Through the pager's lock, whose release lets go of the grab's own
        // hold rather than enabling (`SnapPagerScrollLock`).
        //
        // An engaged comments panel disables the pager for the engagement's
        // whole lifetime (see the note at the engage site) — that freeze is
        // what stops the comment stream chaining into the feed. Thawing to
        // `true` handed it back scrollable, and since nothing else re-applies
        // the lock the chaining stayed broken for the rest of that
        // engagement: the comments dragged the feed with them on every
        // subsequent scroll. Reopening the post appeared to fix it, because
        // that rebuilt the engagement.
        if enabled { host.pagerScrollLock.release(.dismissal) } else { host.pagerScrollLock.hold(.dismissal) }
        // The COMMENT STREAM too, and it is the one that was missed.
        //
        // This freezes "the content" for a dismissal swipe, and the pager was
        // all it froze — which is right for a media post, where the pager is
        // the only thing under the finger. A TEXT post opens straight into its
        // comments, so the surface being swiped is a scroll view hosted in the
        // cell, below the pan and recognising alongside it: a swipe with any
        // vertical component scrolled the comments while the page slid away.
        //
        // Reached through the engaged child rather than by walking subviews:
        // the stream is one specific scroll view, and a descendant sweep would
        // also catch the composer's text view and whatever a cell hosts next.
        let stream = host.commentsContentVC as? PostDetailViewController
        stream?.setStreamScrollEnabled(enabled)
        // ⚠️ AND THE MEDIA CAROUSEL, which is the third one and the one directly
        // under the finger.
        //
        // The note above says the pager is "the only thing under the finger" on
        // a media post. That is true only while the media is one page. A
        // COLLECTION puts a horizontal scroll view exactly where a horizontal
        // dismiss grab begins, so the drag drives both and neither finishes —
        // filmed as the close tearing in half, the page stopped part-way across
        // with the grid beside it.
        //
        // Every realized cell, not just the active one: a neighbour a fling
        // brought within reach can be under the finger by the time the grab
        // begins, and a frozen carousel that is never thawed is a post whose
        // media cannot be paged for the rest of its life.
        //
        // ⚠️ AND THE THAW REACHES EVERY CELL THE FREEZE TOUCHED (#1738): the
        // cells visible at the thaw are not always the ones visible at the
        // freeze — see `CarouselFreezeLedger`.
        let visible = host.collectionView.visibleCells.compactMap { $0 as? SnapFeedCell }
        if enabled {
            host.carouselFreeze.thaw(visible) { $0.setCarouselScrollEnabled($1) }
        } else {
            host.carouselFreeze.freeze(visible) { $0.setCarouselScrollEnabled($1) }
        }
        #if DEBUG
        // `-dismiss-lock-log`: whether the freeze actually REACHED a stream.
        //
        // The conflict this fixes needs a diagonal drag, and the scripted
        // swipe is purely horizontal, so no harness can reproduce it — the
        // one thing a scripted run CAN still establish is that a text post has
        // an engaged panel at swipe time, which is the assumption the forward
        // above rests on. A `stream=nil` here would mean the lock is a no-op.
        if LaunchArgument.dismissLockLog.isPassed() {
            let carousels = visible.filter(\.hasMediaCarousel).count
            print("[dismiss-lock] contentScroll=\(enabled ? "on" : "OFF") "
                  + "stream=\(stream == nil ? "nil" : "engaged") "
                  + "pager=\(host.collectionView.isScrollEnabled ? "SCROLLABLE" : "frozen") "
                  // Whether the freeze reached a CAROUSEL — zero here on a post
                  // whose media is a collection means the lock is a no-op
                  // exactly where the tear was filmed.
                  + "carousels=\(carousels)")
        }
        #endif
    }
}
