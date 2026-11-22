import CoreModels
import CoreNavigation
import LaunchArguments
import PostGrid
import Transitions
import UIKit

extension SnapFeedAssembly {
    /// The plain push, for a caller with no origin to describe.
    ///
    /// `presentSnapFeedHero` reaches the same place when its origin reports
    /// `hasHero == false`, and that is the right shape for a surface that HAS
    /// an origin (a grid tile knows its post, its pixels and its rect). A Maps
    /// text pin has none of that — a symbol on a circle is not a cover, and the
    /// pin carries ids rather than models — so it says so directly instead of
    /// filling a hero origin with fields the plain branch never reads.
    ///
    /// One line of body, and it is the point: everything that makes this push
    /// survivable (the dismissal, its retainer, the tab bar) is in
    /// `pushWithoutFlight`, and a second surface reaching for a bare
    /// `pushViewController` is exactly the regression `PlainPushDismissalTests`
    /// guards.
    public func pushSnapFeed(postIDs: [PostID], from presenter: UIViewController) {
        pushSnapFeed(postIDs: postIDs, from: presenter, sourceIsComplete: false)
    }

    public func pushSnapFeed(postIDs: [PostID], from presenter: UIViewController, sourceIsComplete: Bool) {
        pushSnapFeed(postIDs: postIDs, from: presenter, sourceIsComplete: sourceIsComplete, beneath: nil)
    }

    public func pushSnapFeed(
        postIDs: [PostID], from presenter: UIViewController, sourceIsComplete: Bool,
        beneath: ((UIViewController) -> UIViewController)?
    ) {
        guard !postIDs.isEmpty, let nav = presenter.navigationController else { return }
        pushWithoutFlight(
            makeSnapFeedViewController(postIDs: postIDs, ownsInteractiveDismissal: true, sourceIsComplete: sourceIsComplete),
            on: nav, reveal: nil, beneath: beneath
        )
    }

    public func revealSnapFeed(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: TextRevealOrigin,
        beneath: ((UIViewController) -> UIViewController)?
    ) {
        revealSnapFeed(postIDs: postIDs, from: presenter, origin: origin, beneath: beneath, sourceIsComplete: false)
    }

    public func revealSnapFeed(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: TextRevealOrigin,
        beneath: ((UIViewController) -> UIViewController)?,
        sourceIsComplete: Bool
    ) {
        guard !postIDs.isEmpty, let nav = presenter.navigationController else { return }
        pushWithoutFlight(
            makeSnapFeedViewController(postIDs: postIDs, ownsInteractiveDismissal: true, sourceIsComplete: sourceIsComplete),
            on: nav, reveal: origin, beneath: beneath
        )
    }

    public func textRevealGeometry(closing feed: UIViewController, onto origin: TextRevealOrigin) -> RevealGeometry {
        TextRevealInstaller.geometry(feed: feed, origin: origin, pipeline: imagePipeline)
    }

    /// The reveal's geometry for a CLOSE, built without pushing anything.
    ///
    /// ⚠️ SAFE ON A LOADED FEED, unlike the push — which runs on an empty one
    /// and relies on it. `TextRevealInstaller.geometry` also arms the loading
    /// page, and both of its side effects decline here by construction:
    /// `presentLoadingPage` returns immediately once `orderedIDs` is non-empty,
    /// and the empty ground it sets only ever feeds the resolver's empty
    /// branch.
    ///
    /// Deliberately NOT wrapped in `withDockChoreography`: a caller that owns
    /// its own bottom chrome (the map does) restores it itself, and two owners
    /// would fight over one bar.
    public func makeRevealGeometry(
        dismissing feed: UIViewController,
        origin: TextRevealOrigin,
        onWillClose: (() -> Void)?
    ) -> RevealGeometry {
        (feed as? SnapFeedViewController)?.onWillCloseFeed = onWillClose
        return TextRevealInstaller.geometry(
            feed: feed, origin: origin, pipeline: imagePipeline
        )
    }

    /// Pushes the feed with no flight, and gives it a way back by hand.
    ///
    /// The presentation a post with nothing to fly gets: a native push, plus a
    /// full-surface rightward swipe that scrubs the pop 1:1 and releases on the
    /// same contract every other dismissal in this app uses. Deliberately the
    /// SAME shape For You's text branch had (the tab is gone since #2453),
    /// because a viewer opening the same text post from two surfaces is looking
    /// at one screen and must get one set of gestures.
    ///
    /// ⚠️ Claiming ownership and attaching the swipe are ONE act, never two.
    /// `zoomOwnsInteractiveDismissal` tells `NativePopPolicy` to refuse the
    /// stack's native edge pop — correct only because something else is about
    /// to drive the dismissal. The whole defect this method exists to fix was a
    /// push that inherited the claim (it is the type's default) and attached
    /// nothing: a screen that refused every horizontal drag, edge or surface,
    /// leaving the back chevron as the only way out.
    func pushWithoutFlight(
        _ destination: UIViewController,
        on nav: UINavigationController,
        reveal: TextRevealOrigin?,
        beneath: ((UIViewController) -> UIViewController)? = nil
    ) {
        (destination as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = true
        // A surface that can describe the ROW it is opening from gets the
        // reveal instead of the bare push — the window, not the slide. Every
        // caller of this method reaches it the same way (nothing to fly), so
        // this is the one place a second screen has to be taught.
        let revealing = reveal.map { _ in TextRevealInstaller.isEnabled } ?? false

        // This builder is a struct and `UINavigationController.delegate` is
        // weak, so nothing here would otherwise keep the dismissal alive to see
        // the swipe. The retainer does; the dismissal's own completion clears
        // it, so the cycle lasts exactly as long as the screen does — the same
        // bargain `HeroTransitionRetainer` strikes for the flight.
        let retainer = SlideDismissalRetainer()
        let dismissal = InteractiveSlideDismissal()
        retainer.dismissal = dismissal
        // Accessing `view` loads it so the pan has something to attach to.
        dismissal.attach(to: destination, axes: [.horizontal, .vertical])
        dismissal.onFeedPopped = { nav in
            // Completed pops only — swipe or back button. A cancelled swipe
            // reports nothing here, which is exactly right: the feed is staying
            // up and the bar must stay down.
            Self.restoreTabBar(on: nav)
            retainer.dismissal = nil
        }
        // SAVED, not clobbered — `install` captures whatever owned the stack
        // before this screen and hands it back on teardown. A pushed profile
        // owns it (its own `InteractiveSlideDismissal` for the profile's
        // dismissal), and that has to survive this push intact.
        dismissal.install(on: nav)

        // The dock comes back with the close — through UIKit, once it is
        // committed — and the FEED does that itself, for every way of leaving
        // (`SnapFeedViewController.revealDockForClose`). What stays here is
        // the backstop (`onFeedPopped`, `withDockChoreography`).
        //
        // Hidden BY HAND, through UIKit, for the same reason the flight path
        // states at length: `hidesBottomBarWhenPushed`'s choreography does not
        // scrub with a custom interactive pop, and this screen has one. A
        // window's opening too — it used to keep the bar up for frame 0 and
        // fade its alpha out as the page grew past it (the bar covers the
        // bottom 26pt of the row a reveal departs from); UIKit's own animation
        // uncovers that strip now.
        //
        // ⚠️ Not under `hidesBottomBarWhenPushed` (#769, `flagHidesAppTabBar`).
        if !nav.flagHidesAppTabBar(at: nav.topViewController) {
            nav.tabBarController?.hideTabBarNatively()
        }

        if let reveal, revealing {
            // The OPENING is this reveal's, and it has to say so: a geometry
            // alone no longer means the push is one, now that a media post
            // carries one for the case where the viewer pages onto a text post
            // before closing. See `InteractiveSlideDismissal.revealPresents`.
            dismissal.revealPresents = true
            // ⚠️ AND NO HERO WILL TAKE THIS SCREEN'S CLOSE, so the slide must
            // not hand a media page's pop to one.
            //
            // This screen opened as a WINDOW, and the feed is a pager: page onto
            // a photograph and its post reports `.hero`. The slide then
            // FORWARDS a pop with no gesture behind it — the chevron — to the
            // delegate it displaced. On this path that is never a flight for
            // this feed (nothing here builds one; a profile's own slide or the
            // map's controller answers about a different screen), so the answer
            // is nil, and nil is UIKit's plain pop: the list came back on a cut
            // while a drag on the same page closed as the window. For You's list
            // says the same thing about the same landing (its
            // `heroLandingAcceptsHero` is false for a text row), and so the
            // chevron there closes as the window too.
            dismissal.heroLandingAcceptsHero = { false }
            dismissal.revealGeometry = TextRevealInstaller.geometry(
                feed: destination,
                origin: Self.withDockChoreography(reveal, on: nav),
                pipeline: imagePipeline
            )
        } else {
            // ⚠️ A NATIVE PUSH CLOSES WITH THE NATIVE POP (#2015, the owner:
            // "a screen closes the way it opened"), whatever page is on screen
            // by then. The feed is a pager: page onto a photograph and its post
            // reports `.hero`, and the slide would forward the chevron's pop to
            // the delegate it displaced. Nothing here builds a flight for this
            // feed, so the answer is nil — UIKit's slide — said explicitly, as
            // the window's path says it. No `revealGeometry` either: no window.
            dismissal.heroLandingAcceptsHero = { false }
            // And its vertical closes are PULLS (#2045, #2046): the page lifts
            // under a fixed bar, and a release past the threshold is the same
            // native pop — never a page sliding up or down over the map.
            dismissal.closesByPull = true
        }
        // A place page beneath a semantic cluster's feed: the VERTICAL
        // dismissal's landing, slid under the feed at swipe-begin — the
        // Case-B restaging recipe, inverted (INSERT instead of drop) — so
        // the plain single pop that follows lands on it.
        //
        // THE TWO AXES GO TO DIFFERENT PLACES, and each closes onto what is
        // really there: rightward onto the map's marker, downward onto the
        // post's own card on the place page's Activity tab. One
        // `revealGeometry` cannot describe both, so `prepareForDismissal`
        // swaps it for the live axis — which is early enough by construction,
        // the driver reading the geometry three lines after asking.
        if let beneath {
            // Built NOW and captured STRONGLY: until a vertical swipe
            // inserts it, this closure chain is the page's only owner.
            // Hydration starts inside the builder (`PlaceFeatureBuilder.makeClusterGallery`
            // begins loading), so the first dismissal lands on cards rather
            // than a skeleton.
            let landing = beneath(destination)
            // The marker's own geometry, kept for the rightward leg.
            let markerGeometry = dismissal.revealGeometry
            // ⚠️ THE FALLBACK TRAVELS SIDEWAYS whatever the hand did. A
            // downward slide reads as the page being dropped; the platform's
            // back-direction is the honest look for a close that could not
            // stage its card.
            dismissal.fallbackSlideAxis = .horizontal
            // ⚠️ `dismissal` IS CAPTURED WEAKLY, and the strong capture it
            // replaces was a retain cycle: the driver owns this closure and the
            // closure wrote through the driver, so every dismissal ever prepared
            // kept its driver alive for the life of the process. Invisible to
            // every census — what leaks is a DRIVER, which nothing counts —
            // and one per opened post.
            dismissal.prepareForDismissal = { [weak landing, weak dismissal] axis in
                guard let dismissal else { return }
                // Down onto the place page; right and up (#761) onto the marker.
                guard axis.landsBeneath else {
                    dismissal.revealGeometry = markerGeometry
                    return
                }
                // Staged off the stack, under the chrome it is about to wear.
                (landing as? any FeedBeneathLanding)?.stagingChromeTop = nav.navigationBar.frame.maxY
                // Nil origin — no card to land on — leaves the geometry nil,
                // which is exactly how the driver selects the plain slide.
                dismissal.revealGeometry = (landing as? any FeedBeneathLanding)?
                    .markerFlightLandingOrigin(
                        sizedTo: nav.view.bounds,
                        // The post the viewer is on: its kind picks Popular's
                        // card, and with no Popular card it goes at the head of
                        // Recent. Read HERE because this closure runs before the
                        // driver takes the geometry, which is the last moment
                        // the list can still be arranged.
                        settled: (destination as? SnapFeedViewController)?.activePostID
                    )
                    .map {
                        TextRevealInstaller.geometry(
                            feed: destination, origin: $0, pipeline: imagePipeline
                        )
                    }
            }
            let staged = dismissal.onWillBeginPop
            dismissal.onWillBeginPop = { [weak nav, weak destination] axis in
                staged?(axis)
                guard axis.landsBeneath, let nav, let destination,
                      !nav.viewControllers.contains(landing),
                      let feedIndex = nav.viewControllers.firstIndex(of: destination)
                else { return }
                var stack = nav.viewControllers
                stack.insert(landing, at: feedIndex)
                nav.setViewControllers(stack, animated: false)
                // The removal half, for an abandoned swipe: the page leaves
                // again so the back button and the horizontal close keep
                // their map landing. Both hops are load-bearing — the
                // coordinator exists only once the pop has begun (next
                // turn), and its completion fires inside
                // `completeTransition(false)`'s call stack, where a
                // same-turn `setViewControllers` is silently swallowed
                // (measured on the map's escape; see its cancel closure).
                DispatchQueue.main.async { [weak nav, weak destination] in
                    guard let coordinator = destination?.transitionCoordinator else { return }
                    coordinator.animate(alongsideTransition: nil) { context in
                        guard context.isCancelled else { return }
                        DispatchQueue.main.async { [weak nav, weak destination] in
                            guard let nav, let destination,
                                  nav.topViewController === destination,
                                  nav.viewControllers.contains(landing) else { return }
                            var stack = nav.viewControllers
                            stack.removeAll { $0 === landing }
                            nav.setViewControllers(stack, animated: false)
                        }
                    }
                }
            }
        }
        nav.pushViewController(destination, animated: true)
        #if DEBUG
        // `-zoom-live-log`: the only way a scripted run can tell "attached" from
        // "claimed ownership and attached nothing", which is what the defect
        // looked like from the outside — a screen that renders perfectly and
        // answers no gesture.
        if LaunchArgument.zoomLiveLog.isPassed() {
            let pans = destination.view.gestureRecognizers?
                .filter { $0 is UIPanGestureRecognizer }.count ?? 0
            print("[hero] pushed WITHOUT flight, dismissal pans=\(pans)")
        }
        // `-text-swipe-demo <peak>`: walks the exact begin/update/release path a
        // finger drives, since the simulator injects none. The SAME argument
        // For You's own text branch honours, deliberately — a viewer's thumb
        // does not know which screen opened the post, so neither should the
        // harness that stands in for it.
        //
        // ⚠️ It reports whether the pop is being DRIVEN, not whether the screen
        // went away. With no delegate — or one that does not vend this driver —
        // `popViewController` still pops on UIKit's own animation: the depth
        // changes, the screen leaves, and a harness watching only for that
        // reports success while a real finger would have watched the page jump
        // instead of follow. That distinction is the entire defect.
        let arguments = ProcessInfo.processInfo.arguments
        if let peak = LaunchArgument.textSwipeDemo.doubleValue(in: arguments) {
            // `-zoom-demo-grab-vertical` flips this script to the vertical
            // axis, exactly as it does the zoom demos — the axis a semantic
            // cluster's feed dismisses into its place page on.
            //
            // `-text-swipe-demo-horizontal` overrides it back, for the run that
            // needs BOTH in one process: reach the place page by a vertical
            // dismiss, then leave the post above it sideways. A single
            // process-wide flag cannot say that, which is how this leg went
            // unscripted while the flag was set for the leg before it.
            let axis: ZoomDismissAxis
            if LaunchArgument.textSwipeDemoHorizontal.isPassed(in: arguments) {
                axis = .horizontal
            } else {
                axis = LaunchArgument.zoomDemoGrabVertical.isPassed(in: arguments) ? .vertical : .horizontal
            }
            // Optional second argument: how long to wait. A run that PAGES the
            // feed first has to outlast that paging — a swipe scripted before
            // the pager has settled asks about the post the feed opened on,
            // which is the one case the re-pointing exists for.
            let delay = LaunchArgument.textSwipeDemo.value(at: 2, in: arguments).flatMap(Double.init) ?? 1.5
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let driven = await dismissal.debugPerformSwipe(
                    peakProgress: CGFloat(peak), axis: axis
                )
                print("[text-swipe] peak=\(peak) axis=\(axis) driven=\(driven)")
            }
        }
        #endif
    }
}

/// Keeps a plain push's swipe-to-dismiss alive for the length of the screen.
///
/// Same reason as above, different object: a navigation controller's delegate
/// is weak, a gesture recognizer does not retain its target, and the builder
/// that wires both is a value type. Without this the dismissal would be gone
/// before the first touch — which looks identical to never having attached one.
@MainActor
final class SlideDismissalRetainer {
    var dismissal: InteractiveSlideDismissal?
}
