import Testing
import UIKit
@testable import CoreNavigation

/// The leftward swipe chain (#1525): one arbiter hands a horizontal drag to
/// the stage a screen declares — a panel's driver or an interactive push —
/// and the push leases the stack's delegate for the transition alone.
///
/// Transition COMPLETION is not driven here: a headless test host never runs
/// a percent-driven transition to its end (`InteractivePopToStackTests`'
/// note). The completion is ENDED by hand (`debugEndTransition`), which is the
/// path that gives the lease back; the motion itself is checked in-app.
@Suite(.serialized)
@MainActor
struct SwipeStageArbiterTests {
    /// A window with a stack, and a screen at its root.
    @MainActor
    private final class Stack {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        let nav: UINavigationController
        init() {
            nav = UINavigationController(rootViewController: root)
            window.rootViewController = nav
            window.isHidden = false
            window.layoutIfNeeded()
        }
        deinit { MainActor.assumeIsolated { window.isHidden = true } }
    }

    /// A test screen: declares one stage, records the pushes' ends.
    @MainActor
    private final class Host: SwipeStageHosting {
        var stage: SwipeStage?
        weak var nav: UINavigationController?
        var ends: [Bool] = []
        var willBegin = 0
        func swipeStage(for direction: SwipeDirection, at origin: CGPoint) -> SwipeStage? { stage }
        var swipeNavigationController: UINavigationController? { nav }
        func swipePushWillBegin() { willBegin += 1 }
        func swipePushDidEnd(committed: Bool) { ends.append(committed) }
    }

    @MainActor
    private final class Panel: SwipePanel {
        var events: [String] = []
        func panelDragDidBegin() { events.append("begin") }
        func panelDragDidChange(translationX: CGFloat) { events.append("change \(Int(translationX))") }
        func panelDragDidEnd(velocityX: CGFloat) { events.append("end \(Int(velocityX))") }
        func panelDragDidCancel() { events.append("cancel") }
    }

    // MARK: - The push

    /// Past half, or flung past it, a release commits; short of it, it
    /// springs back.
    @Test func aReleaseCommitsPastHalfOrOnAFlick() {
        #expect(InteractivePushDriver.commits(progress: 0.6, velocity: 0))
        #expect(!InteractivePushDriver.commits(progress: 0.3, velocity: 0))
        #expect(InteractivePushDriver.commits(progress: 0.3, velocity: 2), "a leftward flick commits")
        #expect(!InteractivePushDriver.commits(progress: 0.7, velocity: -3), "a flick back cancels")
        #expect(SwipeStageArbiter.pushProgress(translationX: -201, width: 402) == 0.5)
        #expect(SwipeStageArbiter.pushProgress(translationX: 40, width: 402) == 0, "a rightward drag pushes nothing")
    }

    /// ⚠️ THE GENERIC CASE (#1525): a screen declares a `.push` of a plain
    /// view controller and gets the interactive push with no gesture code —
    /// a real push onto its own stack, driven by the system push animator
    /// and a percent-driven interaction, the delegate LEASED for it.
    @Test func aPushStagePushesAnyScreenInteractively() throws {
        let stack = Stack()
        let host = Host()
        host.nav = stack.nav
        let destination = UIViewController()
        host.stage = .push { destination }
        let arbiter = SwipeStageArbiter(host: host)
        arbiter.install(in: stack.root.view)

        arbiter.debugPick(host.stage)
        arbiter.begin(width: 402)
        #expect(arbiter.isPushing)
        #expect(host.willBegin == 1)
        #expect(stack.nav.viewControllers.last === destination, "not pushed onto the screen's own stack")
        let hub = try #require(NavigationDelegateHub.existing(on: stack.nav))
        #expect(stack.nav.delegate === hub)
        #expect(hub.top === arbiter.debugPushDriver, "the push did not lease the delegate")

        let driver = arbiter.debugPushDriver
        let vended = driver.navigationController(stack.nav, animationControllerFor: .push, from: stack.root, to: destination)
        #expect(vended === driver.debugAnimator, "not the system push animator")
        #expect(driver.navigationController(stack.nav, animationControllerFor: .pop, from: destination, to: stack.root) == nil)
        #expect(driver.navigationController(stack.nav, interactionControllerFor: driver.debugAnimator) === driver.debugInteraction)
        arbiter.change(translationX: -150, width: 402)
        arbiter.end(translationX: -300, velocityX: -800, width: 402)
    }

    /// ⚠️ THE DELEGATE IS GIVEN BACK ON EVERY PATH (#672, #1525): committed
    /// or cancelled, the slot is empty once the transition ends — a delegate
    /// left in it would refuse the profile's full-surface back swipe.
    @Test(arguments: [true, false])
    func theDelegateIsGivenBackWhenThePushEnds(committed: Bool) {
        let stack = Stack()
        let driver = InteractivePushDriver()
        var told: [Bool] = []
        driver.onFinish = { told.append($0) }
        #expect(driver.begin(pushing: UIViewController(), on: stack.nav))
        #expect(stack.nav.delegate != nil)

        driver.debugEndTransition(completed: committed)
        #expect(stack.nav.delegate == nil, "the delegate stayed in the slot after the push")
        #expect(!driver.isPushing)
        #expect(told == [committed])
    }

    /// A driver gone mid-drag still leaves the slot: the lease is weak, and
    /// the end releases what is left.
    @Test func aDriverGoneMidDragLeavesTheSlot() {
        let stack = Stack()
        var driver: InteractivePushDriver? = InteractivePushDriver()
        driver?.begin(pushing: UIViewController(), on: stack.nav)
        let hub = NavigationDelegateHub.existing(on: stack.nav)
        driver = nil
        #expect(hub?.top == nil, "a dead driver still held the lease")
        // The stack's next `didShow` finds the hub idle, and it steps out.
        hub?.navigationController(stack.nav, didShow: stack.root, animated: false)
        #expect(stack.nav.delegate == nil, "the slot kept an idle hub")
    }

    /// ⚠️ A FLICK RELEASED BEFORE UIKIT STARTS THE PUSH (#1525) — it starts
    /// one layout pass after `pushViewController` — waits for the start
    /// instead of being dropped, which froze the push at zero.
    @Test func aReleaseBeforeTheStartWaitsForIt() {
        let interaction = PushInteraction()
        interaction.update(0.3)
        interaction.finish()
        #expect(interaction.debugPendingFinish == true, "the commit was dropped")
        interaction.cancel()
        #expect(interaction.debugPendingFinish == false, "the spring back was dropped")
        interaction.reset()
        #expect(interaction.debugPendingFinish == nil)
    }

    /// A push UIKit never asked the animator for (unanimated, or answered
    /// elsewhere) ends at its `didShow`: the driver would otherwise stay
    /// pushing and refuse every later swipe.
    @Test func aPushThatNeverReachedTheAnimatorEndsAtItsDidShow() {
        let stack = Stack()
        let driver = InteractivePushDriver()
        var told: [Bool] = []
        driver.onFinish = { told.append($0) }
        let pushed = UIViewController()
        #expect(driver.begin(pushing: pushed, on: stack.nav))
        // UIKit asked for the animator: its `didShow` is the animator's to end.
        if driver.navigationController(stack.nav, animationControllerFor: .push, from: stack.root, to: pushed) != nil {
            driver.navigationController(stack.nav, didShow: pushed, animated: true)
            #expect(driver.isPushing, "a didShow ended a push the animator runs")
        }

        driver.debugForgetAnimatorVended()
        driver.navigationController(stack.nav, didShow: pushed, animated: false)
        #expect(!driver.isPushing, "still pushing after the push showed")
        #expect(told == [true])
        #expect(stack.nav.delegate == nil, "the delegate stayed in the slot")
    }

    // MARK: - The panel

    /// A panel stage gets the drag: begin, the translation, the release.
    @Test func aPanelStageGetsTheDrag() {
        let stack = Stack()
        let host = Host()
        let panel = Panel()
        host.stage = .panel(panel)
        let arbiter = SwipeStageArbiter(host: host)
        arbiter.install(in: stack.root.view)
        arbiter.debugPick(host.stage)
        arbiter.begin(width: 402)
        arbiter.change(translationX: -40, width: 402)
        arbiter.end(translationX: -90, velocityX: -500, width: 402)
        #expect(panel.events == ["begin", "change -40", "end -500"])
        #expect(!arbiter.debugIsActive)
        #expect(!arbiter.isPushing, "a panel stage pushed")
    }

    /// No stage, no drag: nothing starts.
    @Test func noStageStartsNothing() {
        let stack = Stack()
        let host = Host()
        let arbiter = SwipeStageArbiter(host: host)
        arbiter.install(in: stack.root.view)
        arbiter.debugPick(nil)
        arbiter.begin(width: 402)
        #expect(!arbiter.debugIsActive && !arbiter.isPushing)
        #expect(stack.nav.delegate == nil)
    }
}
