import Testing
import UIKit

/// UIKit stack-transaction contracts the cluster-gallery navigation shape
/// stands on (the Phase-0 spike for the map cluster gallery), pinned as tests
/// because the design commits to them before any feature code exists:
///
/// 1. **Two-VC insertion**: committing `setViewControllers([map, gallery,
///    feed])` over `[map]` with animation runs ONE push-shaped transition from
///    `map` to `feed`; the mid-stack gallery joins the stack without its view
///    ever being loaded. This is how a semantic-cluster tap lands on the feed
///    with the gallery already beneath it.
/// 2. **Multi-pop pairing**: `popToViewController(map)` from the feed asks the
///    delegate for ONE transition, `feed → map` — never one per removed
///    controller — and removes the gallery without loading it.
///
/// ## What is deliberately NOT tested here
///
/// Transition COMPLETION, of any kind. In a headless test host neither the
/// percent driver's CADisplayLink rewind nor a custom animator's `UIView`
/// animation completion reliably fires — measured twice: a control test of
/// the production-proven "cancelled single pop restores" behaviour timed out
/// with `transitionCoordinator` still alive, and after adding
/// `transitionCoordinator == nil` assertions even the NON-interactive
/// transitions here failed them. (An earlier revision of this file
/// "measured" that a cancelled multi-pop stays popped; that was this
/// artifact.) So this suite pins only the STACK-TRANSACTION facts, which
/// UIKit commits up front and which survive whether or not the transition
/// has settled; everything animated is verified in-app, where displays are
/// real.
///
/// The Case-B horizontal escape therefore avoids resting on any behaviour
/// only a live display can prove: it reorders the stack first
/// (`setViewControllers(_, animated: false)` — the shape
/// `FeedFlowCoordinator.push(on:)` already ships) and then drives an ordinary
/// SINGLE interactive pop, whose cancel path is exercised by every abandoned
/// grab in production. Whether a bare interactive `popTo` could have worked is
/// left unanswered on purpose; the recipe is verified in-app during the
/// cluster-gallery milestone's sim QA.
///
/// ⚠️ `.serialized` is load-bearing: each test pumps the SHARED main run
/// loop, and Swift Testing's default parallelism had multiple live windows
/// animating over it at once — one test's pump advanced another test's
/// transition. Not a UIKit finding; a harness one.
@Suite(.serialized)
@MainActor
struct InteractivePopToStackTests {
    // MARK: - 1. Two-VC insertion

    @Test func animatedSetViewControllersInsertsTheGalleryUnseen() {
        let stack = Stack()
        let gallery = UIViewController()
        let feed = UIViewController()

        stack.nav.setViewControllers([stack.root, gallery, feed], animated: true)
        stack.pump(until: { feed.viewIfLoaded?.window != nil })

        #expect(stack.nav.viewControllers == [stack.root, gallery, feed])
        #expect(stack.nav.topViewController === feed)
        #expect(feed.viewIfLoaded?.window != nil, "the feed must actually be on screen")
        #expect(!gallery.isViewLoaded,
                "the mid-stack gallery must join the stack without even loading its view")
        #expect(stack.delegate.observedOperations == [.push],
                "one push-shaped transition, not one per inserted controller")
        #expect(stack.delegate.observedPairs.first?.from === stack.root)
        #expect(stack.delegate.observedPairs.first?.to === feed)
    }

    // MARK: - 2. Multi-pop pairing

    @Test func aPopToRootRemovesFeedAndGalleryInOneTransition() {
        let stack = Stack()
        let gallery = UIViewController()
        let feed = UIViewController()
        stack.host([stack.root, gallery, feed])

        stack.nav.popToViewController(stack.root, animated: true)
        #expect(stack.delegate.observedPairs.last?.from === feed,
                "the transition is asked for the TOP pair, not per removed controller")
        #expect(stack.delegate.observedPairs.last?.to === stack.root)
        stack.pump(until: { stack.nav.viewControllers == [stack.root] })

        #expect(stack.delegate.observedOperations == [.pop], "one pop, not two")
        #expect(stack.nav.viewControllers == [stack.root])
        #expect(!gallery.isViewLoaded, "the skipped gallery must never load on the way out")
    }

    // MARK: - Fixtures

    /// Window-hosted navigation stack under a custom transition delegate — the
    /// exact runtime shape `ZoomTransitionController` occupies. `@MainActor` on
    /// the nested type, not inherited: stored-property defaults evaluate in the
    /// type's own isolation and UIKit initialisers are main-actor bound.
    @MainActor
    private final class Stack {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        let nav: UINavigationController
        let delegate = TransitionDelegate()

        init() {
            nav = UINavigationController(rootViewController: root)
            nav.delegate = delegate
            window.rootViewController = nav
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        /// Installs a settled stack without animation and clears the delegate's
        /// observation log, so a test's assertions see only its own transition.
        func host(_ controllers: [UIViewController]) {
            nav.setViewControllers(controllers, animated: false)
            window.layoutIfNeeded()
            pump(until: { nav.transitionCoordinator == nil })
            delegate.observedOperations.removeAll()
            delegate.observedPairs.removeAll()
        }

        /// Condition-based settle — never a fixed sleep (see the CI flake
        /// history in InboxTests): pumps the main run loop until `condition`
        /// or a generous ceiling, whichever first.
        func pump(until condition: () -> Bool, timeout: TimeInterval = 5) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
    }

    /// Vends a trivial animator for every push/pop it is asked about — the
    /// minimal stand-in for the zoom stack's delegate. Non-interactive on
    /// purpose; see the suite doc for why interactive completion cannot be
    /// exercised here.
    @MainActor
    private final class TransitionDelegate: NSObject, UINavigationControllerDelegate {
        var observedOperations: [UINavigationController.Operation] = []
        var observedPairs: [(from: UIViewController, to: UIViewController)] = []

        func navigationController(
            _ navigationController: UINavigationController,
            animationControllerFor operation: UINavigationController.Operation,
            from fromVC: UIViewController,
            to toVC: UIViewController
        ) -> (any UIViewControllerAnimatedTransitioning)? {
            observedOperations.append(operation)
            observedPairs.append((from: fromVC, to: toVC))
            return FadeAnimator()
        }
    }

    /// The simplest legal custom animator: a plain `UIView` animation inside
    /// `animateTransition`, honest about cancellation.
    private final class FadeAnimator: NSObject, UIViewControllerAnimatedTransitioning {
        func transitionDuration(
            using transitionContext: (any UIViewControllerContextTransitioning)?
        ) -> TimeInterval { 0.15 }

        func animateTransition(using context: any UIViewControllerContextTransitioning) {
            guard let fromView = context.view(forKey: .from),
                  let toView = context.view(forKey: .to) else {
                context.completeTransition(false)
                return
            }
            if let toVC = context.viewController(forKey: .to) {
                toView.frame = context.finalFrame(for: toVC)
            }
            context.containerView.insertSubview(toView, belowSubview: fromView)
            UIView.animate(withDuration: transitionDuration(using: context)) {
                fromView.alpha = 0
            } completion: { _ in
                fromView.alpha = 1
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
    }
}
