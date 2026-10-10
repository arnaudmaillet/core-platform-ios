import Testing
import UIKit
@testable import CoreNavigation

/// ⚠️ A REVEAL LEG TAKES THE SCREEN'S TOUCHES FOR AS LONG AS IT RUNS (#786).
///
/// The reveal's stage is non-interactive (`RevealStage.makeHost`), and a view
/// that takes no touches passes them to whatever is under it — the grid. A
/// scroll during a close moved the row the window had already measured as its
/// landing, so the window landed on the old rect. Each leg now puts a shield
/// on top of the container, and the container outlives the transition, so the
/// shield has to go on EVERY way a leg can end: landed, reversed, cancelled.
///
/// Every leg is driven through a fake transition context in a visible window,
/// and teardown is waited for by condition, never by clock: the present leg
/// and the grab's release both end on a real animation.
@Suite(.serialized, .timeLimit(.minutes(10)))
@MainActor
struct RevealTouchShieldTests {

    // MARK: - Present

    @Test func anOpeningRevealSwallowsTouchesAndDropsItsShieldWhenItLands() async throws {
        try await hosting { rig in
            let context = rig.context(presenting: true)
            RevealPresentAnimator(geometry: rig.geometry).animateTransition(using: context)

            #expect(rig.hit() is RevealTouchShield, "a touch during the opening reached the grid")

            try await settle { context.completed != nil }
            #expect(context.completed == true)
            #expect(!rig.containerHoldsShield, "the landed opening left its shield in the container")
            #expect(!(rig.hit() is RevealTouchShield))
        }
    }

    @Test func aReversedOpeningDropsItsShieldToo() async throws {
        try await hosting { rig in
            let context = rig.context(presenting: true)
            context.wasCancelled = true
            RevealPresentAnimator(geometry: rig.geometry).animateTransition(using: context)

            #expect(rig.hit() is RevealTouchShield)

            try await settle { context.completed != nil }
            #expect(context.completed == false)
            #expect(!rig.containerHoldsShield, "the reversed opening left its shield in the container")
        }
    }

    // MARK: - Pop (the chevron)

    @Test func aClosingRevealSwallowsTouchesAndDropsItsShieldWhenItLands() async throws {
        try await hosting { rig in
            let context = rig.context(presenting: false)
            let animator = RevealPopAnimator(geometry: rig.geometry)
            let close = try #require(animator.interruptibleAnimator(using: context) as? UIViewPropertyAnimator)

            // THE COMPLAINT: without the shield this was the grid, mid-close.
            #expect(rig.hit() is RevealTouchShield, "a touch during the close reached the grid")

            close.startAnimation()
            close.stopAnimation(false)
            close.finishAnimation(at: .end)
            #expect(context.completed == true)
            #expect(!rig.containerHoldsShield, "the landed close left its shield in the container")
            #expect(!(rig.hit() is RevealTouchShield))
        }
    }

    @Test func aCancelledCloseDropsItsShieldToo() async throws {
        try await hosting { rig in
            let context = rig.context(presenting: false)
            let animator = RevealPopAnimator(geometry: rig.geometry)
            let close = try #require(animator.interruptibleAnimator(using: context) as? UIViewPropertyAnimator)
            #expect(rig.hit() is RevealTouchShield)

            context.wasCancelled = true
            close.startAnimation()
            close.stopAnimation(false)
            close.finishAnimation(at: .start)
            #expect(context.completed == false)
            #expect(!rig.containerHoldsShield, "the cancelled close left its shield in the container")
            #expect(!(rig.hit() is RevealTouchShield))
        }
    }

    // MARK: - Grab release

    @Test func aCommittedGrabShieldsItsSettleAndDropsTheShieldWhenItLands() async throws {
        try await hosting { rig in
            let context = rig.context(presenting: false)
            let grab = RevealDismissInteractionController(geometry: rig.geometry, axis: .horizontal)
            grab.startInteractiveTransition(context)
            grab.update(translation: CGPoint(x: 300, y: 0), in: rig.container)

            grab.release(
                translation: CGPoint(x: 300, y: 0), velocity: .zero, ended: true, in: rig.container
            )
            #expect(rig.hit() is RevealTouchShield, "a touch during the settle reached the grid")

            try await settle { context.completed != nil }
            #expect(context.completed == true)
            #expect(!rig.containerHoldsShield, "the committed grab left its shield in the container")
        }
    }

    @Test func anAbandonedGrabDropsItsShieldToo() async throws {
        try await hosting { rig in
            let context = rig.context(presenting: false)
            let grab = RevealDismissInteractionController(geometry: rig.geometry, axis: .horizontal)
            grab.startInteractiveTransition(context)
            grab.update(translation: CGPoint(x: 20, y: 0), in: rig.container)

            grab.release(translation: CGPoint(x: 20, y: 0), velocity: .zero, ended: true, in: rig.container)
            #expect(rig.hit() is RevealTouchShield)

            try await settle { context.completed != nil }
            #expect(context.completed == false)
            #expect(!rig.containerHoldsShield, "the abandoned grab left its shield in the container")
            #expect(!(rig.hit() is RevealTouchShield))
        }
    }

    // MARK: - Harness

    /// A visible window per test, taken down before the test returns — see the
    /// visible-window release crash: a window freed while still visible is
    /// laid out after it is gone.
    private func hosting(_ body: (Rig) async throws -> Void) async rethrows {
        let rig = Rig()
        defer { rig.takeDown() }
        try await body(rig)
    }

    /// Waits for the leg to report, polling the condition — not a fixed sleep.
    /// The ceiling is the release watcher's own (6 s) with room to spare.
    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private final class Rig {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    let container: UIView
    /// The screen the reveal opens from and closes onto.
    let grid = UIViewController()
    /// The revealed page.
    let page = UIViewController()
    let geometry: RevealGeometry

    init() {
        geometry = RevealGeometry(
            sourceFrame: { _ in CGRect(x: 16, y: 300, width: 370, height: 145) },
            sourceCornerRadius: 18
        )
        container = UIView(frame: window.bounds)
        window.addSubview(container)
        window.isHidden = false
        grid.view.frame = window.bounds
        page.view.frame = window.bounds
    }

    func context(presenting: Bool) -> ShieldTransitionContext {
        container.addSubview(presenting ? grid.view : page.view)
        container.layoutIfNeeded()
        return ShieldTransitionContext(
            container: container,
            from: presenting ? grid : page,
            to: presenting ? page : grid
        )
    }

    func hit() -> UIView? {
        container.hitTest(CGPoint(x: 200, y: 600), with: nil)
    }

    var containerHoldsShield: Bool {
        container.subviews.contains { $0 is RevealTouchShield }
    }

    func takeDown() {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
        window.layoutIfNeeded()
    }
}

/// Just enough of UIKit's transition context to run a reveal leg's terminal
/// branches: views, frames, and a record of how it completed.
@MainActor
private final class ShieldTransitionContext: NSObject, UIViewControllerContextTransitioning {
    let containerView: UIView
    private let from: UIViewController
    private let to: UIViewController
    var wasCancelled = false
    private(set) var completed: Bool?

    init(container: UIView, from: UIViewController, to: UIViewController) {
        containerView = container
        self.from = from
        self.to = to
    }

    var isAnimated: Bool { true }
    var isInteractive: Bool { false }
    var transitionWasCancelled: Bool { wasCancelled }
    var presentationStyle: UIModalPresentationStyle { .none }
    func updateInteractiveTransition(_ percentComplete: CGFloat) {}
    func finishInteractiveTransition() {}
    func cancelInteractiveTransition() { wasCancelled = true }
    func pauseInteractiveTransition() {}
    func completeTransition(_ didComplete: Bool) { completed = didComplete }
    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? {
        key == .from ? from : to
    }
    func view(forKey key: UITransitionContextViewKey) -> UIView? {
        key == .from ? from.view : to.view
    }
    var targetTransform: CGAffineTransform { .identity }
    func initialFrame(for vc: UIViewController) -> CGRect { containerView.bounds }
    func finalFrame(for vc: UIViewController) -> CGRect { containerView.bounds }
}
