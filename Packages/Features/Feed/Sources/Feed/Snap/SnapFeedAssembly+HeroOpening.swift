import CoreModels
import CoreNavigation
import FeedInterface
import LaunchArguments
import PostGrid
import PostSurfaces
import Transitions
import UIKit

extension SnapFeedAssembly {
    public func presentSnapFeedHero(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: SnapFeedHeroOrigin
    ) {
        guard !postIDs.isEmpty, let nav = presenter.navigationController else { return }
        // ⚠️ ONE OPENING AT A TIME. For You and the post list guard their own
        // taps; the screens that open through here (a profile, the place page,
        // Discover, search) did not, so a double tap pushed two feeds, and the
        // second captured the first flight as the delegate to restore.
        guard FeedFeatureBuilder.canOpen(from: presenter, on: nav) else { return }
        let destination = makeSnapFeedViewController(
            postIDs: postIDs, ownsInteractiveDismissal: true, continuation: origin.continuation
        )
        // Hand over the projection the origin is already showing, on BOTH
        // presentations. The flight used to hide the cost of not doing this —
        // the card carries the tile's own pixels, so the destination behind it
        // could be empty for the length of the animation and nobody saw it —
        // which is why this was only ever noticed on the plain push below.
        (destination as? SnapFeedViewController)
            .map { $0.seedProjection(SnapFeedViewController.keepingOpeningKind(GalleryPostProjection.seedModels(from: origin.stream))) }
        // The collection's page the source is showing, and the source
        // following the post's carousel back — the same pair For You's own
        // list handed its feed (until #2453).
        if let feed = destination as? SnapFeedViewController {
            if let page = origin.mediaPage { feed.openMediaPage(page, for: origin.post.id) }
            if let follow = origin.followMediaPage { feed.onMediaPageChanged = follow }
        }
        // ⚠️ OPENED BY ITS COMMENT COUNT — the thread comes up with the page.
        //
        // Handed over as a page instruction rather than acted on at the tap, so
        // the destination spends the engagement's layout when it is ready to.
        // The reveal point is the rect the flight is about to fly, so the
        // thread is revealed OUT of the photograph rather than arriving over
        // it. Same shape as For You's own chip.
        if origin.opensComments {
            (destination as? SnapFeedViewController)?.openComments(
                for: origin.post.id, revealingFrom: origin.frame(presenter.view)
            )
        }
        // The snap feed is the only thing this builds, and it conforms — but
        // the factory is typed `UIViewController` for callers who do not care.
        //
        // ⚠️ `hasHero` is asked FIRST, and it is not the same question as
        // whether the cast succeeds. A text-only post has no media surface at
        // either end of a flight, so there is nothing to fly even though the
        // destination is perfectly flyable. Both answers land on the same feed;
        // only the way in differs, which is the right thing to degrade.
        //
        // Historically this method had no such branch: an origin with no hero
        // was flown anyway (from a rect it had to invent), and a destination
        // that failed the cast was silently dropped on the floor — the tap did
        // nothing at all. Neither is a presentation.
        // Reduce Motion: the stack's own push, no flight and no window
        // (`HeroMotionPolicy`).
        let reducesMotion = HeroMotionPolicy.prefersNativePush
        // A list's row of words (#2243) opens with the native push too: no
        // window, so the plain push's close — the native pop, whatever page
        // the feed shows by then (`heroLandingAcceptsHero = { false }`), its
        // vertical closes pulls.
        let nativePush = reducesMotion || origin.opensWithNativePush
        guard origin.hasHero, !nativePush,
              let flyable = destination as? any ZoomTransitionDestination else {
            pushWithoutFlight(destination, on: nav, reveal: nativePush ? nil : origin.textReveal)
            return
        }
        // The feed is a pager and this origin lands where it took off, so the
        // one thing the source cannot work out for itself is what the viewer is
        // leaving — asked of the feed, at staging, never captured here.
        let source = ExternalHeroZoomSource(
            origin: origin,
            settle: { [weak destination] in
                let feed = destination as? any SnapFeedSettleReporting
                return (id: feed?.settledPostID, cover: feed?.settledCoverImage, page: feed?.settledMediaPage)
            }
        )
        // ⚠️ THE SESSION OWNS THE FLIGHT'S LIFE (`HeroPushSession`): this
        // builder is a struct and cannot hold it, so the session keeps itself
        // alive until it closes, leases the stack's delegate slot (SAVED, not
        // assumed nil — a profile owns the slot through its own slide dismissal
        // before it pushes anything, and restoring nil orphaned it), and runs
        // ONE close-out for a return AND a reversed push. The reversed push
        // used to restore the dock and nothing else, leaking the whole flight.
        let session = HeroPushSession(
            source: source, destination: flyable, on: nav, retainsItself: true
        )
        let transition = session.controller
        // The pushed feed owns its dismissal grab, exactly as it does when the
        // For You grid opens it — otherwise the stack's edge gesture and the
        // flight's own grab both try to drive one pop.
        (destination as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = true

        // The card close armed beside the flight and its landing, kept for as
        // long as the session (the close holds its landing weakly).
        let retainer = HeroTransitionRetainer()
        session.onClose = { [weak nav] _ in
            origin.setConcealed(false)
            // Released a turn later with the session: the close-out runs
            // inside the card close's own forwarded `didShow`.
            let released = (retainer.cardClose, retainer.cardCloseLanding)
            retainer.cardClose = nil
            retainer.cardCloseLanding = nil
            DispatchQueue.main.async { withExtendedLifetime(released) {} }
            // A BACKSTOP for the dock — the close's commit has normally shown
            // it already (below). Through UIKit, never an alpha.
            Self.restoreTabBar(on: nav)
        }
        // An abandoned grab leaves the post up — and never raised the dock,
        // which waits for a COMMITTED release, so there is nothing to undo.
        // ⚠️ BOTH AXES GO HOME TO THE TILE, including for a post opened from
        // the PLACE PAGE.
        //
        // That page used to split them: the vertical grab flew home while the
        // horizontal one ESCAPED past the gallery to the map, on the reading
        // that a rightward swipe is the platform's back gesture and the map is
        // where the flow began. It read as a level being skipped. A post opened
        // from a place belongs to that place, so both ways out of it land
        // there, and leaving the place for the map is the place's own gesture
        // to offer (`installMapReturnIfTop`) — one screen, one level, each
        // time.
        //
        // What went with the split: the escape's slide, the stack surgery that
        // dropped the gallery mid-gesture and re-inserted it on a cancel, and
        // the `setDismissSource` registration that pointed a pop at a marker.
        // A gesture that no longer crosses two levels needs none of it.
        // ⚠️ AND THE CARD-SHAPED CLOSE RIDES ALONG FOR EVERY PRESENTER THAT CAN
        // LAND ONE — not only the place page.
        //
        // This used to ask `presenter as? PlaceProfileViewController`, so a
        // PROFILE opened its media posts with a flight and nothing beside it:
        // page onto a text post and both zoom grabs refuse the `.card` close,
        // the flight's animator declines it, and the stack's edge pop is
        // disclaimed — no drag at all, and a chevron that fell through to
        // UIKit's plain pop. Filmed on a profile's Activity tab as the list
        // coming back on a cut, while For You's Following list, which has
        // always armed this close, revealed onto its card. See
        // `cardCloseLanding(for:origin:pipeline:dock:)`.
        let cardLanding = FeedFeatureBuilder.cardCloseLanding(
            for: presenter, origin: origin, pipeline: imagePipeline,
            dock: { Self.withDockChoreography($0, on: nav) }
        )
        // THE GRAB. Without it this push had no dismissal gesture at all:
        // claiming `zoomOwnsInteractiveDismissal` above tells the stack's
        // native edge-swipe to stay out of the way, which is correct only
        // because the flight attaches its own — and a claim with nothing
        // behind it leaves the screen unswipeable. Accessing `view` loads it
        // so the pan has something to attach to.
        transition.attachInteractiveDismissal(
            to: destination.view, axes: [.horizontal, .vertical]
        ) { [weak nav, weak transition, weak session, weak destination] in
            // ⚠️ NOT WHILE A CARD CLOSE HOLDS THE SLOT. It forwards a `.hero`
            // pop to this flight already, and taking the slot from it was
            // permanent: after a cancelled grab, paging to a text post and
            // dragging ran UIKit's plain pop (this controller refuses `.card`),
            // and the card close never heard a `didShow` again, so it leaked
            // on every committed grab, with the row it concealed.
            if let transition, let nav, session?.holdsDelegateSlot == false {
                NavigationDelegateHub.of(nav).lease(transition)
            }
            // ⚠️ NOTHING ABOUT THE DOCK HERE any more. Grab-begin used to put
            // the bar's state back at alpha 0 and the landing showed it. The
            // feed brings it back itself, through UIKit, once its close is
            // committed — see `SnapFeedViewController.revealDockForClose`.
            // The post is what leaves (#1144), never whatever is on top.
            destination?.closeScreen(whenBusy: .drop)
        }
        #if DEBUG
        // `-zoom-live-log`: the grab is invisible until a finger arrives, and
        // the simulator has none — so this is the only way a scripted run can
        // tell "attached" from "claimed ownership and attached nothing", which
        // is what left profile-opened posts unswipeable.
        if LaunchArgument.zoomLiveLog.isPassed() {
            let pans = destination.view.gestureRecognizers?
                .filter { $0 is UIPanGestureRecognizer }.count ?? 0
            print("[hero] pushed with dismissal grab: pans=\(pans)")
        }
        #endif
        #if DEBUG
        // `-hero-demo-grab`: dismiss the pushed post by grab once it lands, so a
        // scripted run can see the surface UNDERNEATH in its returned state.
        // The reveal that runs while the post covers it is only observable there.
        if LaunchArgument.heroDemoGrab.isPassed() {
            transition.onDestinationShown = { [weak transition] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    transition?.debugScriptedGrab()
                }
            }
        }
        #endif
        // ⚠️ Hidden BY HAND, not with `hidesBottomBarWhenPushed`.
        //
        // The feed reached for that flag twice and measured the same defect both
        // times — most recently on the plain percent driver this path also uses:
        // its bottom-bar choreography does not scrub with a custom interactive
        // pop, so the bar arrives fully rendered at pop-begin and stands over the
        // post for the whole length of a grab. See `FeedFlowCoordinator.push`,
        // which hides on the push and restores on the completed pop; this is the
        // same cure for the same push, arriving from a profile instead of a pin.
        //
        // Nothing else was hiding it here: `syncTabBarVisibility` runs on tab
        // selection, never on a push, and this push replaces the navigation
        // delegate with the flight — so the shell hears nothing either.
        //
        // ⚠️ AFTER THE PUSH'S FIRST FRAME (#2126): the hide's own work was 7–10
        // ms of the tap's turn, ahead of the card's first movement. Asked
        // here, before the push changes the top; done once the turn's commit
        // is out, and only while this feed is still the one on top.
        #if DEBUG
        // `-tabbar-flag`: the A/B this decision rests on. Swaps the hand-managed
        // hide for `hidesBottomBarWhenPushed`, so the two can be filmed against
        // each other on the same grab rather than argued about.
        let usesFlag = LaunchArgument.tabbarFlag.isPassed()
        if usesFlag { destination.hidesBottomBarWhenPushed = true }
        let hidesBar = !usesFlag && !nav.flagHidesAppTabBar(at: nav.topViewController)
        #else
        // ⚠️ NOT UNDER `hidesBottomBarWhenPushed` (#769): a profile over a
        // conversation has handed the bar to UIKit already, and an explicit
        // hide there outlived the pops (`flagHidesAppTabBar`).
        let hidesBar = !nav.flagHidesAppTabBar(at: nav.topViewController)
        #endif
        session.takeDelegateSlot()
        // No `session.prepareDestination()`: this feed is built fresh on every
        // tap, so the pre-paid layout would be a cold one paid between the
        // finger lifting and the flight starting — the map measured that as a
        // pause before the animation (see `MapsViewController`). Only a REUSED
        // destination (For You's) gains from it.
        // ⚠️ THE STACK SETTLED FIRST: a push in the same turn as one that has
        // not been laid out yet (a screen pushed without animation, a host
        // just presented) is dropped by UIKit. The bar's hide used to settle
        // the stack by the way, before it moved after the push (#2126). On a
        // settled stack this lays nothing out.
        nav.view.layoutIfNeeded()
        nav.pushViewController(destination, animated: true)
        if hidesBar {
            nav.tabBarController?.hideTabBarNativelyAfterCommit { [weak nav, weak destination] in
                destination != nil && nav?.topViewController === destination
            }
        }
        // ⚠️ AFTER THE PUSH, and that is the whole of whether it works. The
        // line above hands the stack's delegate to the flight, so a driver
        // installed before it captures a slot it is about to lose — and a
        // dismissal it never hears about is one UIKit never asks for an
        // interaction controller for, which reads as a dead gesture. Installing
        // here makes the FLIGHT what this driver saves and forwards a `.hero`
        // pop back to. The map's own card-close says the same thing about the
        // same ordering.
        if let cardLanding {
            Self.attachTileCardClose(
                feed: destination, landing: cardLanding, on: nav,
                retainer: retainer, session: session
            )
        }
    }

    /// The way back for a post the viewer PAGED onto that has nothing to fly.
    ///
    /// ⚠️ THE PRESENTATION WAS CHOSEN AT THE TAP. A tile opens with a hero;
    /// swipe to a text post and there is no media left for that hero to carry.
    /// Both zoom grabs then refuse — they gate on `zoomDismissalKind != .card`
    /// BEFORE they look at an axis — the pop animator declines for the same
    /// reason, and this push has already disclaimed the stack's native edge
    /// gesture. Measured one level up on the map, where the drag did nothing at
    /// all on either axis and the chevron was the only way out; the map cured
    /// it with `attachCardCloseAlongsideFlight` and this path never got the
    /// equivalent.
    ///
    /// ⚠️ BOTH AXES, like every other card-close.
    ///
    /// It was vertical-only for exactly as long as the horizontal axis had a
    /// second slide on it — the escape past this page to the map, which also
    /// claimed `.card`, and two `InteractiveSlideDismissal`s claiming the same
    /// kind on the same drag is the one thing the arbitration cannot resolve.
    /// The escape is gone; the narrowing outlived it by one commit, and what it
    /// left behind was a page with NOTHING on its horizontal axis: the flight
    /// refuses `.card` before it looks at an axis, and the only driver that
    /// would take it was armed elsewhere. Open a post from Activity, page onto
    /// a text one, swipe right — nothing at all happened. Reported.
    static func attachTileCardClose(
        feed: UIViewController,
        landing: any CardCloseLanding,
        on nav: UINavigationController,
        retainer: HeroTransitionRetainer,
        session: HeroPushSession
    ) {
        let close = InteractiveSlideDismissal()
        retainer.cardClose = close
        // It holds the stack's slot on the flight's behalf, so the session's
        // close may take the slot back from it.
        session.registerForwarder(close)
        // A landing that is not a screen has no other owner — see
        // `HeroTransitionRetainer.cardCloseLanding`. A screen needs no help.
        if landing is RowCardCloseLanding { retainer.cardCloseLanding = landing }
        // The shared rules — both axes, arbitrated, staged ONCE and only for a
        // close that carries a card — are `armAsCardCloseAlongsideFlight`'s,
        // the same call For You's grid makes. What is this host's is only the
        // landing, and the staging MOVES a scroll position and releases a
        // concealment, which is why the once-only latch matters here.
        close.armAsCardCloseAlongsideFlight(on: feed) { [weak landing, weak close] feed in
            guard let landing, let close else { return false }
            close.revealGeometry = landing.cardCloseGeometry(dismissing: feed)
            return true
        }
        // ⚠️ THE DOCK COMES BACK WITH A ROW'S CLOSE, the way it does from For
        // You's list and from this builder's own reveal push: the feed shows
        // it through UIKit once the close commits
        // (`SnapFeedViewController.revealDockForClose`), and
        // `withDockChoreography`'s `dismissalDidEnd` — which
        // `RowCardCloseLanding` already carries — is the landing's backstop.
        // The backstop: whatever animated the close, nothing stays hidden. The
        // staging conceals a tile and only the reveal's own completion pays
        // that back, so a pop finished by anything else would leave a hole.
        close.onFeedPopped = { [weak landing] _ in
            landing?.clearLandingConcealment()
            retainer.cardClose = nil
            retainer.cardCloseLanding = nil
        }
        // AFTER the push, so the flight controller is what `install` captures
        // and a `.hero` pop forwards straight back to it.
        close.install(on: nav)
        #if DEBUG
        // `-tile-card-close-demo <peak>`: the driver's OWN scripted route.
        //
        // Nothing else can reach it. `debugScriptedGrab` picks among the ZOOM
        // drivers, every one of which refuses `.card` before it looks at an
        // axis; `-text-swipe-demo` is bound to whichever slide its own block
        // closes over, and this one has no block. A driver with no scripted
        // route is a driver nobody verifies — the hole that had just been
        // closed for the neighbouring leg.
        let arguments = ProcessInfo.processInfo.arguments
        if let peak = LaunchArgument.tileCardCloseDemo.doubleValue(in: arguments) {
            // Optional second argument: how long to wait. The default is the
            // usual beat after the push, but a run that pages the feed first
            // has to outlast that paging — a swipe scripted before the pager
            // has SETTLED asks about the post the feed opened on, which is the
            // one row this driver is not for.
            let delay = LaunchArgument.tileCardCloseDemo.value(at: 2, in: arguments).flatMap(Double.init) ?? 2.5
            Task { @MainActor [weak close, weak feed] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // The three things that decide whether this driver may claim
                // the drag at all, said before it tries: a refusal and a
                // failure look identical from the outside.
                let kind = (feed as? any ZoomTransitionDestination)?.zoomDismissalKind
                // Both axes carry this driver now, so a run has to be able to
                // ask for either — the defect that put them back was one axis
                // silently having no tenant at all.
                let axis: ZoomDismissAxis = arguments
                    .contains("-tile-card-close-demo-horizontal") ? .horizontal : .vertical
                let driven = await close?.debugPerformSwipe(
                    peakProgress: CGFloat(peak), axis: axis
                )
                let settled = (feed as? any SnapFeedSettleReporting)?.settledPostID
                print("[tile-card-close] peak=\(peak) axis=\(axis) settled=\(settled?.rawValue ?? "nil")"
                    + " kind=\(kind.map(String.init(describing:)) ?? "nil")"
                    + " geometry=\(close?.revealGeometry != nil) driven=\(driven ?? false)")
            }
        }
        #endif
    }
}

/// Keeps what is armed beside a hero flight — its card close and that close's
/// landing — for as long as the flight. The flight itself is kept by its
/// `HeroPushSession`; `FeedFeatureBuilder` is a value type and holds neither.
@MainActor
final class HeroTransitionRetainer {
    /// The VERTICAL card-shaped close of a gallery-opened post — the way back
    /// for a page the viewer swiped onto that has no media to fly. Nil'd by
    /// both close-outs, because the flight's return and the escape's landing
    /// are two different exits and either can be the last one.
    var cardClose: InteractiveSlideDismissal?
    /// The landing that close stages, when it is not a screen the stack
    /// already owns — a surface's own ROW, described by its `TextRevealOrigin`
    /// (`RowCardCloseLanding`). The close holds its landing weakly, as it must
    /// for a screen, so an object nothing else owns has to be kept here.
    var cardCloseLanding: (any CardCloseLanding)?
}
