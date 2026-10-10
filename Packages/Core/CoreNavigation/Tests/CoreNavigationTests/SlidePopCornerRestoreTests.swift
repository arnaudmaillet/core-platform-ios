import Testing
import UIKit
@testable import CoreNavigation

/// ⚠️ THE SLIDE POP HANDS THE FEED'S LAYER BACK AS IT FOUND IT (#787).
///
/// `TimelineSlidePopAnimator` borrows the reused feed's root layer for the
/// bezel rounding, and used to give it back as `0` / `false` — literals — so a
/// feed that rounds or clips itself lost its corners on every pop. A cancel
/// was worse: the reset was a 0.2 s animation that landed AFTER
/// `completeTransition`, so a push started in that window inherited a clipped,
/// rounded feed.
///
/// Driven through a fake transition context in a visible window, waiting on
/// the leg's own completion by condition, never by clock. The bezel radius is
/// FORCED: read from the screen, it is 0 on a square-cornered device (iPhone
/// SE), where the leg writes nothing and "rounded during the leg" fails.
@Suite(.serialized, .timeLimit(.minutes(10)))
@MainActor
struct SlidePopCornerRestoreTests {

    @Test func aCompletedSlidePopHandsTheFeedItsOwnCornersBack() async throws {
        try await hosting { rig in
            let context = rig.context()
            TimelineSlidePopAnimator(axis: .horizontal, bezelRadius: { _ in 44 }).animateTransition(using: context)
            // The leg really did borrow the layer — or this test proves nothing.
            #expect(LayerCornerStyle(capturing: rig.feed.view.layer) != rig.resting,
                    "the leg never rounded the feed: the restore went untested")

            try await settle { context.completed != nil }
            #expect(context.completed == true)
            #expect(context.cornersAtCompletion == rig.resting)
            #expect(LayerCornerStyle(capturing: rig.feed.view.layer) == rig.resting,
                    "the committed pop reset the feed's corners to literals")
        }
    }

    @Test func aCancelledSlidePopRestoresTheFeedsCornersBeforeItCompletes() async throws {
        try await hosting { rig in
            let context = rig.context()
            context.wasCancelled = true
            TimelineSlidePopAnimator(axis: .horizontal, bezelRadius: { _ in 44 }).animateTransition(using: context)
            #expect(LayerCornerStyle(capturing: rig.feed.view.layer) != rig.resting)

            try await settle { context.completed != nil }
            #expect(context.completed == false)
            // THE COMPLAINT: at `completeTransition` the feed was still clipped
            // and rounded, with its reset still to run.
            #expect(context.cornersAtCompletion == rig.resting,
                    "the cancelled pop completed with the feed still wearing the bezel rounding")
            #expect(LayerCornerStyle(capturing: rig.feed.view.layer) == rig.resting)
            let trailing = rig.feed.view.layer.animationKeys() ?? []
            #expect(!trailing.contains { $0.contains("corner") || $0.contains("masksToBounds") },
                    "a corner animation outlived the transition: \(trailing)")
        }
    }

    // MARK: - Harness

    /// A visible window per test, taken down before the test returns.
    private func hosting(_ body: (Rig) async throws -> Void) async rethrows {
        let rig = Rig()
        defer { rig.takeDown() }
        try await body(rig)
    }

    /// Polls the condition — not a fixed sleep — with a generous ceiling.
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
    let feed = UIViewController()
    let landing = UIViewController()
    /// A feed that rounds and clips ITSELF, on a subset of corners and on
    /// circular arcs — every field the leg writes is off its default.
    let resting: LayerCornerStyle

    init() {
        container = UIView(frame: window.bounds)
        window.addSubview(container)
        window.isHidden = false
        feed.view.frame = window.bounds
        landing.view.frame = window.bounds
        let layer = feed.view.layer
        layer.cornerRadius = 7
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.masksToBounds = true
        layer.cornerCurve = .circular
        resting = LayerCornerStyle(capturing: layer)
    }

    func context() -> CornerTransitionContext {
        container.addSubview(feed.view)
        container.layoutIfNeeded()
        return CornerTransitionContext(container: container, from: feed, to: landing)
    }

    func takeDown() {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
        window.layoutIfNeeded()
    }
}

/// Just enough of UIKit's transition context to run the slide's terminal
/// branches, plus the feed's corners at the moment it was told to complete.
@MainActor
private final class CornerTransitionContext: NSObject, UIViewControllerContextTransitioning {
    let containerView: UIView
    private let from: UIViewController
    private let to: UIViewController
    var wasCancelled = false
    private(set) var completed: Bool?
    private(set) var cornersAtCompletion: LayerCornerStyle?

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
    func completeTransition(_ didComplete: Bool) {
        cornersAtCompletion = LayerCornerStyle(capturing: from.view.layer)
        completed = didComplete
    }
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
