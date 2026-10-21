import UIKit

/// A navigation PUSH driven by the finger (#1525): a real
/// `pushViewController` onto the stack, its progress following a drag, that
/// commits or springs back on release.
///
/// UIKit has no public interactive push. It asks for an interaction
/// controller only when a navigation delegate vends an animator, so the
/// driver LEASES the stack's delegate slot (`NavigationDelegateHub`) for the
/// transition alone and vends `SystemPushAnimator` — the system push, redrawn
/// — with a percent-driven interaction.
///
/// ⚠️ **THE LEASE IS GIVEN BACK ON EVERY PATH** — committed, cancelled, or the
/// driver gone mid-drag. Any navigation delegate left in the slot makes UIKit
/// refuse the full-surface back swipe on a screen that hides the tab bar
/// (#672, `NavigationDelegateHub`'s note): the profile pushed here would then
/// only pop from its edge. The animator's completion releases the lease
/// (and the hub steps out of the slot once it is idle); the lease is weak,
/// so a driver that dies first is pruned at the hub's next `didShow`.
///
/// Generic: it pushes any view controller. The profile (#1525) is its first
/// client.
@MainActor
public final class InteractivePushDriver: NSObject, UINavigationControllerDelegate {
    /// Past this share of the width a release commits.
    public nonisolated static let commitThreshold: CGFloat = 0.5
    /// How far a release's speed carries the push on, in seconds of travel —
    /// the flick projection UIKit's own interactive transitions use.
    public nonisolated static let flickProjection: CGFloat = 0.15

    private weak var navigationController: UINavigationController?
    private let interaction = PushInteraction()
    private let animator = SystemPushAnimator()
    /// The screen being pushed, while the push runs.
    private weak var pushed: UIViewController?
    /// Whether a push is running (from `begin` to its end).
    public private(set) var isPushing = false
    /// UIKit took the animator for this push.
    private var animatorVended = false
    /// Told once the push ended: true when it committed.
    public var onFinish: ((Bool) -> Void)?

    override public init() {
        super.init()
        interaction.wantsInteractiveStart = true
    }

    /// Starts pushing `viewController` onto `navigationController`, at zero
    /// progress. False (nothing started) while a push or another transition
    /// runs.
    @discardableResult
    public func begin(pushing viewController: UIViewController, on navigationController: UINavigationController) -> Bool {
        guard !isPushing, navigationController.transitionCoordinator == nil else { return false }
        self.navigationController = navigationController
        pushed = viewController
        isPushing = true
        animatorVended = false
        interaction.reset()
        NavigationDelegateHub.of(navigationController).lease(self)
        animator.onEnd = { [weak self, weak navigationController] completed in
            // The lease goes back whatever happens to the driver.
            if let navigationController, let self {
                NavigationDelegateHub.existing(on: navigationController)?.release(self)
            }
            self?.finish(committed: completed)
        }
        navigationController.pushViewController(viewController, animated: true)
        return true
    }

    /// The drag's progress, 0 (nothing pushed) to 1 (pushed).
    public func update(progress: CGFloat) {
        guard isPushing else { return }
        interaction.update(min(max(progress, 0), 0.999))
    }

    /// The release: commits past `commitThreshold` once the speed is
    /// projected (`velocity` in progress per second), otherwise springs back.
    public func end(progress: CGFloat, velocity: CGFloat) {
        guard isPushing else { return }
        if Self.commits(progress: progress, velocity: velocity) {
            interaction.finish()
        } else {
            interaction.cancel()
        }
    }

    /// Springs back, as a cancelled gesture does.
    public func cancel() {
        guard isPushing else { return }
        interaction.cancel()
    }

    /// Whether a release at `progress` and `velocity` commits. Pure, for tests.
    public nonisolated static func commits(progress: CGFloat, velocity: CGFloat) -> Bool {
        progress + velocity * flickProjection > commitThreshold
    }

    #if DEBUG
    /// Ends the transition as the animator's completion would — a headless
    /// test host never runs one to its end. Tests.
    func debugEndTransition(completed: Bool) { animator.onEnd?(completed) }
    /// The animator and interaction UIKit is handed. Tests.
    var debugAnimator: SystemPushAnimator { animator }
    var debugInteraction: PushInteraction { interaction }
    /// As if UIKit never asked for the animator. Tests.
    func debugForgetAnimatorVended() { animatorVended = false }
    #endif

    private func finish(committed: Bool) {
        guard isPushing else { return }
        isPushing = false
        pushed = nil
        onFinish?(committed)
    }

    // MARK: - UINavigationControllerDelegate

    public func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        guard operation == .push, isPushing, toVC === pushed else { return nil }
        animatorVended = true
        return animator
    }

    /// ⚠️ A PUSH UIKIT NEVER ASKED THE ANIMATOR FOR (it ran unanimated, or
    /// another lease answered) never reaches the animator's completion: it
    /// ends here, or the driver would stay "pushing" and refuse every swipe.
    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        guard isPushing, !animatorVended else { return }
        NavigationDelegateHub.existing(on: navigationController)?.release(self)
        finish(committed: viewController === pushed)
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        guard isPushing, animationController === animator else { return nil }
        return interaction
    }
}

/// The percent-driven interaction, safe to end before it starts.
///
/// ⚠️ UIKIT STARTS A PUSH ONE LAYOUT PASS AFTER `pushViewController`: a flick
/// released first would call `finish()` on an interaction with no context —
/// a no-op — and leave the push frozen at zero. The release waits here for
/// `startInteractiveTransition`, then runs.
final class PushInteraction: UIPercentDrivenInteractiveTransition {
    private var hasStarted = false
    private var pendingPercent: CGFloat = 0
    private var pendingFinish: Bool?

    /// Forgets the previous push.
    func reset() {
        hasStarted = false
        pendingPercent = 0
        pendingFinish = nil
    }

    override func startInteractiveTransition(_ transitionContext: any UIViewControllerContextTransitioning) {
        super.startInteractiveTransition(transitionContext)
        hasStarted = true
        if pendingPercent > 0 { super.update(pendingPercent) }
        if let finishes = pendingFinish {
            pendingFinish = nil
            if finishes { super.finish() } else { super.cancel() }
        }
    }

    override func update(_ percentComplete: CGFloat) {
        guard hasStarted else { pendingPercent = percentComplete; return }
        super.update(percentComplete)
    }

    override func finish() {
        guard hasStarted else { pendingFinish = true; return }
        super.finish()
    }

    override func cancel() {
        guard hasStarted else { pendingFinish = false; return }
        super.cancel()
    }

    #if DEBUG
    var debugPendingFinish: Bool? { pendingFinish }
    #endif
}

/// The system's push, redrawn for an interactive push (#1525): the incoming
/// screen slides in from the trailing edge with a soft shadow on its leading
/// side, the outgoing one moves a third of the way out (the system's
/// parallax) and dims a little. A plain `UIView` animation: linear while the
/// percent-driven interaction scrubs it (it freezes the container's layer
/// time), finished or reversed on the interaction's completion curve.
@MainActor
public final class SystemPushAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    public static let duration: TimeInterval = 0.5
    /// How far the outgoing screen moves, as a share of the width.
    public static let parallax: CGFloat = 0.3
    /// How dark the outgoing screen gets.
    public static let dimming: CGFloat = 0.1

    /// Told when the transition completed (true) or was cancelled.
    var onEnd: ((Bool) -> Void)?

    public func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        Self.duration
    }

    public func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        let width = container.bounds.width
        guard let from = transitionContext.view(forKey: .from),
              let to = transitionContext.view(forKey: .to),
              let toController = transitionContext.viewController(forKey: .to) else {
            let completed = !transitionContext.transitionWasCancelled
            transitionContext.completeTransition(completed)
            onEnd?(completed)
            return
        }
        to.frame = transitionContext.finalFrame(for: toController)
        container.addSubview(to)
        to.transform = CGAffineTransform(translationX: width, y: 0)
        to.layer.shadowColor = UIColor.black.cgColor
        to.layer.shadowOpacity = 0.2
        to.layer.shadowRadius = 8
        to.layer.shadowOffset = CGSize(width: -2, height: 0)
        to.layer.shadowPath = UIBezierPath(rect: to.bounds).cgPath
        let dim = UIView(frame: from.bounds)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        from.addSubview(dim)

        UIView.animate(
            withDuration: Self.duration, delay: 0,
            options: transitionContext.isInteractive ? [.curveLinear] : [.curveEaseInOut]
        ) {
            to.transform = .identity
            from.transform = CGAffineTransform(translationX: -width * Self.parallax, y: 0)
            dim.alpha = Self.dimming
        } completion: { [weak self] _ in
            dim.removeFromSuperview()
            from.transform = .identity
            to.transform = .identity
            to.layer.shadowOpacity = 0
            to.layer.shadowPath = nil
            let completed = !transitionContext.transitionWasCancelled
            if !completed { to.removeFromSuperview() }
            transitionContext.completeTransition(completed)
            self?.onEnd?(completed)
        }
    }
}
