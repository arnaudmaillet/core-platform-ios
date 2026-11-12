import Testing
import UIKit
@testable import CoreNavigation

/// A re-grab reads a caught pose back into the drag's terms (#2362): the
/// position exactly, the shrink exactly at the catch and back on the curve at
/// both ends.
@MainActor
struct ZoomGrabCatchTests {
    private typealias Grab = ZoomDismissInteractionController
    private let width: CGFloat = 402

    /// What the drag would pose for a translation, along the horizontal axis —
    /// the same banding `applyDrag` applies.
    private func bandedOffset(_ translation: CGPoint) -> CGPoint {
        let along = translation.x >= 0
            ? ZoomTransitionGeometry.rubberBand(
                translation.x, limit: ZoomTransitionGeometry.forwardDragLimit(forSpan: width)
            )
            : ZoomTransitionGeometry.rubberBand(translation.x, limit: ZoomTransitionGeometry.backDragLimit)
        let across = ZoomTransitionGeometry.rubberBand(
            translation.y, limit: ZoomTransitionGeometry.crossDriftLimit
        )
        return CGPoint(x: along, y: across)
    }

    @Test func theBandRunsBackwards() {
        for value in stride(from: -50.0, through: 170.0, by: 10.0) {
            let limit: CGFloat = value < 0 ? 60 : 180
            let banded = ZoomTransitionGeometry.rubberBand(CGFloat(value), limit: limit)
            let back = ZoomTransitionGeometry.inverseRubberBand(banded, limit: limit)
            #expect(abs(back - CGFloat(value)) < 1e-6, "\(value) came back as \(back)")
        }
    }

    /// The caught position IS the position the drag poses at the catch's
    /// translation: no step under the finger.
    @Test func theCaughtPositionIsExact() {
        let offset = CGPoint(x: 48, y: -9)
        let caught = ZoomGrabCatch(offset: offset, scale: 0.97, axis: .horizontal, span: width)
        let posed = bandedOffset(caught.translation)
        #expect(abs(posed.x - offset.x) < 1e-6)
        #expect(abs(posed.y - offset.y) < 1e-6)
    }

    /// The caught size IS the size the drag poses at the catch, and the curve
    /// takes over toward both ends: whole at the page, the floor at the span.
    @Test func theCaughtShrinkIsExactAndRejoinsTheCurve() {
        let caught = ZoomGrabCatch(offset: CGPoint(x: 48, y: 0), scale: 0.97, axis: .horizontal, span: width)
        #expect(abs(Grab.grabScale(forEase: caught.ease(at: caught.progress)) - 0.97) < 1e-9)
        #expect(caught.ease(at: 0) == 0, "a re-grab pulled back to the page left the card shrunk")
        #expect(abs(caught.ease(at: 1) - 1) < 1e-9, "a re-grab missed the floor at the full span")
        // Continuous and monotonic on the way, both sides of the catch.
        var previous = caught.ease(at: 0)
        for step in 1...1000 {
            let value = caught.ease(at: CGFloat(step) / 1000)
            #expect(value >= previous - 1e-9, "the shrink went back at \(step)")
            #expect(value - previous < 0.01, "a step of \(value - previous) at \(step)")
            previous = value
        }
    }

    /// A cancel spring's overshoot, caught past the page: the card a hair
    /// larger than the page, and the drag forward takes it back to the curve.
    @Test func anOvershootCaughtPastThePageStaysContinuous() {
        let caught = ZoomGrabCatch(offset: CGPoint(x: -3, y: 0), scale: 1.01, axis: .horizontal, span: width)
        #expect(caught.progress == 0)
        #expect(abs(Grab.grabScale(forEase: caught.ease(at: 0)) - 1.01) < 1e-9)
        #expect(abs(caught.ease(at: 1) - 1) < 1e-9)
    }

    /// A grab from rest continues from nothing.
    @Test func aGrabFromRestIsTheCurve() {
        for step in 0...10 {
            let progress = CGFloat(step) / 10
            #expect(ZoomGrabCatch.none.ease(at: progress) == Grab.grabEase(at: progress))
        }
    }
}

/// The grab itself, staged on a fake transition (#2362): no zoom out at the
/// grab, and a grab during the cancel spring that catches the card where it
/// is, in the same transition.
@MainActor
struct DismissDragCatchTests {
    /// No detach dip: at the grab, and one runloop turn later (where the dip
    /// used to fire), the card is the page — its size, nothing animating it —
    /// and it stays that size until the finger travels.
    @Test func theGrabDoesNotZoomOut() async throws {
        try await hosting { rig in
            rig.driver.beginGrab()
            let card = try #require(rig.driver.debugFlightCard)
            let page = try #require(rig.driver.debugPageFrame)
            #expect(card.bounds.size == page.size)
            #expect(Self.springKeys(on: card.layer).isEmpty)

            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(card.bounds.size == page.size, "the card shrank at the grab")
            #expect(Self.springKeys(on: card.layer).isEmpty, "something animates the card at the grab")

            rig.driver.updateDrag(translation: .zero, in: rig.feed.view)
            #expect(card.bounds.size == page.size, "a grab held still zoomed out")
            #expect(rig.feed.lastState?.progress == 0)

            rig.driver.releaseGrab(translation: .zero, velocity: .zero, ended: true, in: rig.feed.view)
            try await Self.settle { rig.context.completed != nil }
        }
    }

    /// A grab during the cancel spring catches the card where it is — the
    /// presented pose, scale and position — with the transition still open,
    /// and the drag carries on from there without a step.
    @Test func aGrabDuringTheCancelStartsFromThePresentedPose() async throws {
        try await hosting { rig in
            let view = rig.feed.view!
            rig.driver.beginGrab()
            rig.driver.updateDrag(translation: CGPoint(x: 120, y: 0), in: view)
            rig.driver.releaseGrab(translation: CGPoint(x: 120, y: 0), velocity: .zero, ended: true, in: view)

            // Released short: a cancel, NOT yet reported — the transition stays
            // interactive while the spring carries the card home.
            #expect(rig.driver.isCancelSettling)
            #expect(!rig.context.wasCancelled, "the cancel was reported at the release")
            #expect(rig.context.completed == nil)
            let shield = try #require(rig.driver.debugReleaseShield)
            let regrab = try #require(shield.gestureRecognizers?.first)
            #expect(rig.driver.gestureRecognizerShouldBegin(regrab), "the re-grab was refused during the cancel")

            let card = try #require(rig.driver.debugFlightCard)
            let page = try #require(rig.driver.debugPageFrame)
            let presentedCenter = CGPoint(x: page.midX + 30, y: page.midY + 4)
            let presentedSize = CGSize(width: page.width * 0.97, height: page.height * 0.97)
            rig.driver.catchSettlingCard(
                presentedCenter: presentedCenter, presentedSize: presentedSize,
                panTranslation: CGPoint(x: 12, y: 0)
            )

            #expect(rig.driver.isInteracting)
            #expect(!rig.driver.isCancelSettling)
            #expect(!rig.context.wasCancelled)
            #expect(rig.context.completed == nil)
            #expect(!rig.driver.gestureRecognizerShouldBegin(regrab), "a second re-grab while held")
            #expect(Self.near(card.center, presentedCenter), "caught at \(card.center)")
            #expect(abs(card.bounds.width - presentedSize.width) < 0.01, "caught at \(card.bounds.width)")
            #expect(Self.springKeys(on: card.layer).isEmpty, "the cancel spring still runs under the hand")
            // The destination was told the caught pose as a held state.
            #expect(rig.feed.lastState?.isSettling == false)

            // The re-grab pan has not moved since its `.began`: nothing moves.
            rig.driver.updateDrag(translation: CGPoint(x: 12, y: 0), in: view)
            #expect(Self.near(card.center, presentedCenter, tolerance: 0.01))
            #expect(abs(card.bounds.width - presentedSize.width) < 0.01)

            // It travels on: the card follows, and keeps shrinking gently.
            rig.driver.updateDrag(translation: CGPoint(x: 52, y: 0), in: view)
            #expect(card.center.x > presentedCenter.x)
            #expect(card.bounds.width < presentedSize.width)
            #expect(card.bounds.width > page.width * 0.9)

            // Released short again: this time the cancel lands and is reported.
            rig.driver.releaseGrab(translation: CGPoint(x: 12, y: 0), velocity: .zero, ended: true, in: view)
            try await Self.settle { rig.context.completed != nil }
            #expect(rig.context.wasCancelled)
            #expect(rig.context.completed == false)
            #expect(rig.driver.debugReleaseShield == nil)
        }
    }

    /// A commit's spring is untouchable: no re-grab.
    @Test func aCommitCannotBeCaught() async throws {
        try await hosting { rig in
            let view = rig.feed.view!
            rig.driver.beginGrab()
            rig.driver.updateDrag(translation: CGPoint(x: 300, y: 0), in: view)
            rig.driver.releaseGrab(translation: CGPoint(x: 300, y: 0), velocity: .zero, ended: true, in: view)
            #expect(!rig.driver.isCancelSettling)
            let regrab = try #require(rig.driver.debugReleaseShield?.gestureRecognizers?.first)
            #expect(!rig.driver.gestureRecognizerShouldBegin(regrab))
            try await Self.settle { rig.context.completed != nil }
            #expect(rig.context.completed == true)
        }
    }

    // MARK: - Harness

    /// Animation keys on a layer other than the give's transform.
    private static func springKeys(on layer: CALayer) -> [String] {
        (layer.animationKeys() ?? []).filter {
            (layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath != "transform"
        }
    }

    private static func near(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1e-6) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    private func hosting(_ body: (CatchRig) async throws -> Void) async rethrows {
        let rig = CatchRig()
        defer { rig.takeDown() }
        try await body(rig)
    }

    private static func settle(until condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private final class CatchRig {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    let container: UIView
    let feed = CatchFeed()
    let presenter = UIViewController()
    let source = CatchSource()
    let driver = ZoomDismissInteractionController()
    let context: CatchTransitionContext

    init() {
        container = UIView(frame: window.bounds)
        window.addSubview(container)
        window.isHidden = false
        presenter.view.frame = window.bounds
        feed.view.frame = window.bounds
        container.addSubview(feed.view)
        container.layoutIfNeeded()
        let staged = CatchTransitionContext(container: container, from: feed, to: presenter)
        context = staged
        driver.attach(to: feed.view, source: source, destination: feed) { [driver] in
            driver.startInteractiveTransition(staged)
        }
    }

    func takeDown() {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
        window.layoutIfNeeded()
    }
}

@MainActor
private final class CatchSource: NSObject, ZoomTransitionSource {
    var zoomLandingAcceptsHero: Bool { true }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        CGRect(x: 20, y: 300, width: 120, height: 160)
    }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { CatchCard() }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class CatchCard: UIView, ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) { layer.cornerRadius = radius }
}

private final class CatchFeed: UIViewController, ZoomTransitionDestination {
    private(set) var lastState: ZoomDismissState?
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
    func setZoomDismissState(_ state: ZoomDismissState) { lastState = state }
}

/// Just enough of UIKit's transition context to run the grab: views, frames,
/// and a record of how it was reported and completed.
private final class CatchTransitionContext: NSObject, UIViewControllerContextTransitioning {
    let containerView: UIView
    private let from: UIViewController
    private let to: UIViewController
    private(set) var wasCancelled = false
    private(set) var completed: Bool?

    init(container: UIView, from: UIViewController, to: UIViewController) {
        containerView = container
        self.from = from
        self.to = to
    }

    var isAnimated: Bool { true }
    var isInteractive: Bool { true }
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
