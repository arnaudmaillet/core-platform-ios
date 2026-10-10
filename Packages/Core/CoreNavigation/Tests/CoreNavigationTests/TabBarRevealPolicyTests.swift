import Testing
import UIKit
@testable import CoreNavigation

/// A CANCELLED DRAG IS NOT A RETURN.
///
/// The grid hides the system tab bar by hand for a post's visit, and used to
/// put it back in `viewWillAppear`. That reads as "I am back", but UIKit runs
/// it when an interactive pop BEGINS — before the finger has said whether it
/// means it. Release below the completion threshold and the feed sprang back
/// with the bar left standing over it, permanently: the cleanup in
/// `viewWillDisappear` is guarded on being the top view controller and the
/// stack is already restored by then, and the completed-pop callback never
/// fires for a cancel. Nothing owned taking it away again.
///
/// The fix is a timing distinction with no syntax at the call site, which is
/// why it is a value with tests rather than an `if` — three appearance paths
/// reach one line and only one may act on it now.
struct TabBarRevealPolicyTests {
    /// A tab switch back, or any non-animated return: nothing is moving, so
    /// there is nothing to be out of step with.
    @Test func aStillScreenRevealsOutright() {
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: false, isTransitioning: false,
                                          isInteractive: false) == .immediately)
    }

    /// The regression. A scrub is a question, not an answer — the reveal
    /// belongs to whatever the finger turns out to have meant.
    @Test func aScrubDefersTheReveal() {
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: false, isTransitioning: true,
                                          isInteractive: true) == .whenTransitionCommits)
    }

    /// …but ONLY a scrub. A back-button pop is already committed, and holding
    /// its reveal back put the bar on a screen that had finished moving —
    /// measured at ~400ms after landing, which reads as a snap. Deferring is
    /// for uncertainty, not for transitions in general.
    @Test func aButtonPopDoesNotDeferBecauseItCannotBeTakenBack() {
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: false, isTransitioning: true,
                                          isInteractive: false) == .immediately)
    }

    /// …and the deferred answer, both ways round. The cancel branch is the bug.
    @Test func onlyACommittedTransitionReveals() {
        #expect(TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: false))
        #expect(TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: true) == false,
                "a cancelled drag leaves the pushed screen on display — the bar stays under it")
    }

    /// NATIVE CHROME IS UIKIT'S (2026-09-28): a close of the snap feed shows
    /// the dock through UIKit, on UIKit's animation, as soon as it is
    /// COMMITTED — and a scrub is committed by its release, exactly like any
    /// other scrub. It is not held for the landing any more (that took an alpha
    /// written by hand, which the rule forbids).
    @Test func aScrubbedReturnFromTheFeedRevealsWhenItCommits() {
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: true, isTransitioning: true,
                                          isInteractive: true) == .whenTransitionCommits)
    }

    /// …but a close of the feed that no finger drives cannot un-hide the bar
    /// from inside itself: measured, the bar comes back as a state every API
    /// reports as shown and nothing draws. Its owner shows it BEFORE the pop;
    /// the policy's answer is the backstop for a pop nobody announced, after it.
    @Test func aButtonCloseOfTheFeedRevealsAfterTheTransition() {
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: true, isTransitioning: true,
                                          isInteractive: false) == .afterTransition)
    }

    /// …and with nothing moving there is nothing to wait for: waiting for a
    /// transition that does not exist would leave the dock down for good.
    @Test func aReturnWithNoTransitionRevealsOutright() {
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: true, isTransitioning: false,
                                          isInteractive: false) == .immediately)
    }
}

/// Which landing a close of the snap feed may give the dock back to.
///
/// Asked by the feed itself before it raises the bar, so a wrong answer is
/// either a screen left with no dock (the place page, once) or a dock raised
/// over a screen UIKit's own `hidesBottomBarWhenPushed` keeps bar-less (a
/// pushed profile).
@MainActor
struct ShowsAppTabBarTests {
    @Test func aTabRootShowsTheDock() {
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        #expect(nav.showsAppTabBar(for: root))
    }

    /// UIKit's rule: anything above the root that hides the bar hides it for
    /// every screen above it too.
    @Test func aScreenUnderHidesBottomBarWhenPushedShowsNone() {
        let root = UIViewController()
        let pushed = UIViewController()
        pushed.hidesBottomBarWhenPushed = true
        let above = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        nav.setViewControllers([root, pushed, above], animated: false)
        #expect(nav.showsAppTabBar(for: pushed) == false)
        #expect(nav.showsAppTabBar(for: above) == false)
        #expect(nav.showsAppTabBar(for: root))
    }

    /// …but the ROOT's own flag means nothing to UIKit, and nothing here.
    @Test func theRootsOwnFlagIsIgnored() {
        let root = UIViewController()
        root.hidesBottomBarWhenPushed = true
        let nav = UINavigationController(rootViewController: root)
        #expect(nav.showsAppTabBar(for: root))
    }

    @Test func noLandingShowsNothing() {
        let nav = UINavigationController(rootViewController: UIViewController())
        #expect(nav.showsAppTabBar(for: nil) == false)
    }

    /// ⚠️ A DEFERRED BAND INSTALL RUNS ONLY FOR A SCREEN STILL ON SHOW (#758):
    /// a screen popped before its push committed or landed must not install
    /// its band (and arm the bar's collapse) over the screen beneath.
    @MainActor
    @Test func onlyTheScreenOnShowMayStillClaimTheBottom() {
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.isHidden = false
        defer { window.isHidden = true }
        let pushed = UIViewController()
        let child = UIViewController()
        pushed.addChild(child)
        pushed.view.addSubview(child.view)
        child.didMove(toParent: pushed)
        nav.pushViewController(pushed, animated: false)
        nav.view.layoutIfNeeded()

        #expect(pushed.isStillTheScreenOnShow)
        #expect(child.isStillTheScreenOnShow, "a screen nested in the top one counts as it")
        #expect(!root.isStillTheScreenOnShow, "a screen under the top one is not on show")

        nav.popViewController(animated: false)
        nav.view.layoutIfNeeded()
        #expect(!pushed.isStillTheScreenOnShow, "a popped screen may no longer claim the bottom")
        #expect(root.isStillTheScreenOnShow)
        #expect(!UIViewController().isStillTheScreenOnShow, "off-window")
    }

    /// ⚠️ A TAB'S ROOT ALWAYS SHOWS THE TAB BAR (#769): an explicit hide left
    /// behind by a path back is undone by the selected tab's root as it
    /// appears — and only by it: a pushed screen, or another tab's root,
    /// leaves the bar alone.
    @MainActor
    @Test func theSelectedTabsRootPutsTheBarBack() async {
        let inbox = UIViewController()
        let profile = UIViewController()
        let tabs = UITabBarController()
        let messages = UINavigationController(rootViewController: inbox)
        let other = UINavigationController(rootViewController: profile)
        tabs.viewControllers = [messages, other]
        tabs.selectedViewController = messages
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = tabs
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        tabs.view.layoutIfNeeded()

        let pushed = UIViewController()
        messages.pushViewController(pushed, animated: false)
        tabs.setTabBarHidden(true, animated: false)
        pushed.ensureAppTabBarAsTabRoot()
        profile.ensureAppTabBarAsTabRoot()
        await nextMainTurn()
        #expect(tabs.isTabBarHidden, "a pushed screen, or another tab's root, showed the bar")

        messages.popToRootViewController(animated: false)
        tabs.setTabBarHidden(true, animated: false)
        inbox.ensureAppTabBarAsTabRoot(stillWanted: { false })
        await nextMainTurn()
        #expect(tabs.isTabBarHidden, "a root that no longer wants the bar showed it")

        inbox.ensureAppTabBarAsTabRoot()
        // ⚠️ Not inline: an un-hide from `viewDidAppear` never renders.
        #expect(tabs.isTabBarHidden, "the bar was shown inline")
        await nextMainTurn()
        #expect(!tabs.isTabBarHidden, "the selected tab's root left the bar hidden")
    }

    /// UIKit's flag owns the bar from the first flagged screen up (#769).
    @MainActor
    @Test func theFlagOwnsTheBarFromTheFirstFlaggedScreenUp() {
        let root = UIViewController()
        let conversation = UIViewController()
        conversation.hidesBottomBarWhenPushed = true
        let profile = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        nav.setViewControllers([root, conversation, profile], animated: false)

        #expect(!nav.flagHidesAppTabBar(at: root))
        #expect(nav.flagHidesAppTabBar(at: conversation))
        #expect(nav.flagHidesAppTabBar(at: profile))
        #expect(!nav.flagHidesAppTabBar(at: UIViewController()), "a screen off the stack")
        #expect(!nav.showsAppTabBar(for: profile))
    }

    @MainActor
    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
