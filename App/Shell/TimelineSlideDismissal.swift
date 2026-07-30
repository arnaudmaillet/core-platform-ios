import CoreNavigation
import UIKit

/// Interactive rightward swipe-to-pop for the menu-pushed timeline feed —
/// gesture parity with the pin feed's grab, minus the pin.
///
/// Deliberately NOT the native `interactivePopGestureRecognizer`: that is
/// edge-only (this pan covers the whole surface, like the grab), it is
/// disabled by the feed's custom back item, and it completes on UIKit's own
/// threshold — both dismissals must release on the one shared contract
/// (`ZoomTransitionGeometry.shouldCompleteDismissal`: 35% of width, or a
/// 900 pt/s flick).
///
/// Deliberately NOT the pin path's free-floating interaction controller:
/// with no pin to land on there is no 2D float, no detach dip, no clip-morph
/// — progress here is one scalar, which is exactly the rail
/// `UIPercentDrivenInteractiveTransition` scrubs. The slide stays strictly
/// horizontal and never touches the hero pipeline (`ZoomFlight`,
/// `poseAtSource`, live-player mirroring).
///
/// Owned by `FeedFlowCoordinator`; installed as the stack's delegate around
/// each push and self-uninstalled (restoring any prior delegate) when the
/// feed leaves the stack.
@MainActor
final class TimelineSlideDismissal: NSObject {
    private weak var feedViewController: UIViewController?
    private weak var navigationController: UINavigationController?
    /// Whatever delegate the stack had when the feed was pushed (e.g. a
    /// dormant `ZoomTransitionController`, when a deep link pushes the timeline
    /// above a pin-opened feed) — restored on teardown.
    private weak var savedDelegate: (any UINavigationControllerDelegate)?

    /// Non-nil exactly while a swipe drives a pop; the delegate vends the
    /// slide animator (and this driver) only then, so back-button pops and
    /// every other transition on the stack stay native.
    private var interaction: UIPercentDrivenInteractiveTransition?

    /// Fired when the feed has left the stack (completed pops only — swipe
    /// or back button; a cancelled swipe reports nothing). The owner restores
    /// the manually hidden tab bar here.
    var onFeedPopped: ((UINavigationController) -> Void)?

    /// Installs the pan on the feed's view. Called once; the retained feed
    /// keeps its recognizer across pushes.
    func attach(to feedViewController: UIViewController) {
        guard self.feedViewController == nil else { return }
        self.feedViewController = feedViewController
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        feedViewController.view.addGestureRecognizer(pan)
    }

    /// Takes the stack's delegate slot for the feed's time on `nav`. The
    /// previous delegate is saved, not clobbered: `navigationController(_:didShow:)`
    /// hands the slot back the moment the feed is off the stack.
    func install(on nav: UINavigationController) {
        guard nav.delegate !== self else { return }
        savedDelegate = nav.delegate
        nav.delegate = self
        navigationController = nav
    }

    private func teardown() {
        if let nav = navigationController, nav.delegate === self {
            nav.delegate = savedDelegate
        }
        savedDelegate = nil
        navigationController = nil
    }

    // MARK: - Gesture

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = feedViewController?.viewIfLoaded else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            // Direction was vetted in gestureRecognizerShouldBegin — claim
            // immediately so the screen is under the finger at frame 0.
            beginSwipe()
        case .changed:
            interaction?.update(ZoomTransitionGeometry.dismissProgress(
                translation: translation.x, span: view.bounds.width
            ))
        case .ended, .cancelled:
            releaseSwipe(
                translation: translation,
                velocity: gesture.velocity(in: view),
                ended: gesture.state == .ended,
                in: view
            )
        default:
            break
        }
    }

    private func beginSwipe() {
        guard interaction == nil,
              let nav = navigationController,
              let feed = feedViewController, nav.topViewController === feed else { return }
        // Freeze the pager so a diagonal drag can't page mid-pop.
        (feed as? any ZoomTransitionDestination)?.setContentScrollEnabled(false)
        let interaction = UIPercentDrivenInteractiveTransition()
        interaction.completionCurve = .easeOut
        self.interaction = interaction
        // Triggers the pop; the delegate below vends the slide animator and
        // this driver because `interaction` is now non-nil.
        nav.popViewController(animated: true)
    }

    private func releaseSwipe(translation: CGPoint, velocity: CGPoint, ended: Bool, in view: UIView) {
        guard let interaction else { return }
        self.interaction = nil
        // The retained feed outlives every pop — always thaw its scrolling.
        (feedViewController as? any ZoomTransitionDestination)?.setContentScrollEnabled(true)

        let progress = ZoomTransitionGeometry.dismissProgress(
            translation: translation.x, span: view.bounds.width
        )
        // The shared release contract — identical to the pin grab's.
        let commit = ended && ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: progress, velocity: velocity.x
        )
        commit ? interaction.finish() : interaction.cancel()
    }

    #if DEBUG
    /// Scripted swipe for sim recordings (`-feed-swipe-demo`): touch injection
    /// is impossible in the simulator, so this walks the exact
    /// begin/update/release path a finger drives. Whether it completes or
    /// springs back is decided by the same threshold logic as a real release.
    func debugPerformSwipe(peakProgress: CGFloat) async {
        guard let view = feedViewController?.viewIfLoaded else { return }
        beginSwipe()
        let peak = peakProgress * view.bounds.width
        let steps = 30
        for step in 1...steps {
            try? await Task.sleep(nanoseconds: 16_000_000)
            let t = CGFloat(step) / CGFloat(steps)
            interaction?.update(ZoomTransitionGeometry.dismissProgress(
                translation: peak * t, span: view.bounds.width
            ))
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        releaseSwipe(
            translation: CGPoint(x: peak, y: 0), velocity: .zero, ended: true, in: view
        )
    }
    #endif
}

// MARK: - UINavigationControllerDelegate

extension TimelineSlideDismissal: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        // Every pop of OUR feed rides the slide animator — swipe-driven or
        // back-button. Not only for visual consistency: the manual tab-bar
        // restore in `didShow` is stomped by a NATIVE pop's own end-of-
        // transition bar bookkeeping (verified: the bar stayed hidden after a
        // back-button pop, while the same restore call held after custom
        // pops). The feed's push, and everything else on this stack, stay
        // native.
        guard operation == .pop, fromVC === feedViewController else { return nil }
        return TimelineSlidePopAnimator()
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        interaction
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        // Completed transitions only (a cancelled swipe reports nothing): once
        // the feed is off the stack, hand the delegate slot back.
        let feedStillOnStack = feedViewController.map {
            navigationController.viewControllers.contains($0)
        } ?? false
        if !feedStillOnStack {
            teardown()
            onFeedPopped?(navigationController)
        }
    }
}

// MARK: - Direction and coexistence

extension TimelineSlideDismissal: UIGestureRecognizerDelegate {
    /// Mirrors the pin grab's conflict story: begin only for a rightward,
    /// predominantly horizontal movement, so the feed's vertical paging and
    /// pull-to-refresh never see a competitor.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard interaction == nil,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let feed = feedViewController, let view = feed.viewIfLoaded,
              let nav = navigationController, nav.topViewController === feed,
              // `topViewController` is already the feed while a pop ABOVE it is
              // still animating (reachable since the native edge swipe works on
              // pushed profiles/details): beginning here would call
              // `popViewController` mid-transition — undefined, and it can
              // strand the percent driver. Refuse; the next swipe retries.
              nav.transitionCoordinator == nil
        else { return false }
        if let destination = feed as? any ZoomTransitionDestination,
           !destination.isReadyForInteractiveDismissal { return false }
        let velocity = pan.velocity(in: view)
        return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true // coexist with the pager's pan; we self-gate by direction above
    }
}

// MARK: - Animator

/// The pop leg the swipe scrubs: a native-style slide — the feed exits right
/// at 1:1 while the underlying screen advances from its parallax offset under
/// a fading dim. Linear inside, so scrubbed progress tracks the finger; the
/// percent driver's completion curve eases the remainder on release.
private final class TimelineSlidePopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// How far (fraction of width) the underlying screen sits shifted left
    /// before the pop reveals it — the native parallax depth.
    private let parallax: CGFloat = 0.3

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0.35
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        guard let fromView = context.view(forKey: .from),
              let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to) else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        toView.frame = context.finalFrame(for: toVC)
        container.insertSubview(toView, belowSubview: fromView)

        let dim = UIView(frame: toView.bounds)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.15)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        toView.addSubview(dim)

        // Bezel-matched corner rounding, SET (not animated) at frame 0: at
        // rest the clipped corners sit exactly behind the device's own
        // rounded bezel, so the mask is invisible until the slide carries the
        // view away from it — no entry animation to jump, and (crucially)
        // nothing for the percent driver's frozen layer clock to strand
        // mid-value during a scrub. The radius is a static model value for
        // the transition's whole life. A plain cornerRadius clip with no
        // shadow composites on the GPU without an offscreen pass, so the
        // 1:1 tracking stays cheap.
        let radius = ScreenGeometry.cornerRadius(behind: fromView)
        if radius > 0 {
            fromView.layer.cornerCurve = .continuous
            fromView.layer.cornerRadius = radius
            fromView.layer.masksToBounds = true
        }

        toView.transform = CGAffineTransform(translationX: -container.bounds.width * parallax, y: 0)
        UIView.animate(
            withDuration: transitionDuration(using: context),
            delay: 0,
            options: [.curveLinear]
        ) {
            fromView.transform = CGAffineTransform(translationX: container.bounds.width, y: 0)
            toView.transform = .identity
            dim.alpha = 0
        } completion: { _ in
            dim.removeFromSuperview()
            fromView.transform = .identity
            toView.transform = .identity
            if context.transitionWasCancelled {
                // The feed is back at full screen, where the rounding hides
                // behind the bezel again — animate it off anyway so the
                // retained view carries no mask outside dismissals.
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
                    fromView.layer.cornerRadius = 0
                } completion: { _ in
                    fromView.layer.masksToBounds = false
                }
            } else {
                // Committed: the view held the bezel radius to its last
                // on-screen frame; it is unparented now, so reset silently
                // for the retained feed's next push.
                fromView.layer.cornerRadius = 0
                fromView.layer.masksToBounds = false
            }
            context.completeTransition(!context.transitionWasCancelled)
        }
    }
}
