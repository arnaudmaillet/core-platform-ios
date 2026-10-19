import CoreNavigation
import UIKit

/// Keeps the native edge-swipe-to-pop alive on a stack whose delegate slot is
/// sometimes occupied by a custom transition owner (`InteractiveSlideDismissal`,
/// `ZoomTransitionController` — the map's pin flight and the For You grid's).
///
/// UIKit's built-in gesture delegate quietly refuses to *begin* the native
/// interactive pop while the navigation controller's delegate implements the
/// transition callbacks — even for pops that delegate answers `nil` (native)
/// for. Verified in-sim with synthesized edge drags: a profile pushed above
/// the feed would not budge, while the same profile on a bare stack popped
/// natively. Taking the recognizer's delegate slot bypasses that veto; the
/// begin decision below re-implements the safety UIKit's own delegate
/// provided (never at a root, never mid-transition, honor explicit back
/// suppression) plus this app's one exclusion: snap surfaces own their
/// dismissal gestures and must never race a competing edge pop.
///
/// One enabler per tab stack, installed by `MainTabCoordinator` and retained
/// for the stack's lifetime — the policy is evaluated per swipe, so no
/// install/uninstall choreography is needed around pushes.
@MainActor
final class NativePopGestureEnabler: NSObject {
    private weak var navigationController: UINavigationController?

    init(taking navigationController: UINavigationController) {
        self.navigationController = navigationController
        super.init()
        // The recognizer is created in the nav's viewDidLoad; force the load
        // so installation at shell start() can't silently no-op on a tab
        // whose view hasn't displayed yet.
        navigationController.loadViewIfNeeded()
        navigationController.interactivePopGestureRecognizer?.delegate = self
        // ⚠️ AND THE FULL-SURFACE ONE, THROUGH A PROXY (#1324): UIKit's own
        // delegate vetoes it whenever the stack has a delegate, which left
        // plain pushes (a profile) carrying a custom slide that raced it. The
        // proxy relays everything but that veto and adds the same policy as
        // the edge's, plus the screen's own gate (`ContentPopGating`).
        if #available(iOS 26.0, *), let content = navigationController.interactiveContentPopGestureRecognizer {
            // ⚠️ ONLY IN FRONT OF THE DELEGATE IT WAS BUILT FOR (#1328): when
            // UIKit's delegate is missing, or no longer answers the veto, it
            // stays in place and the back swipe is the edge's alone.
            guard ContentPopDelegateProxy.canInterpose(on: content.delegate) else {
                #if DEBUG
                let found = content.delegate.map { String(describing: type(of: $0)) } ?? "nil"
                print("[content-pop] UIKit's delegate (\(found)) does not answer the veto: left in place, back swipe from the edge only")
                #endif
                return
            }
            let proxy = ContentPopDelegateProxy(system: content.delegate) { [weak self] recognizer in
                self?.contentPopShouldBegin(recognizer) ?? false
            }
            content.delegate = proxy
            contentPopProxy = proxy
        }
    }

    /// Held here: a recognizer's delegate is weak.
    private var contentPopProxy: ContentPopDelegateProxy?

    /// The edge's policy, then the screen's gate at the touch's origin.
    private func contentPopShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizerShouldBegin(recognizer),
              let top = navigationController?.topViewController else { return false }
        guard let gate = top as? any ContentPopGating else { return true }
        return gate.allowsContentPop(beginningAt: recognizer.location(in: top.view), in: top.view)
    }
}

extension NativePopGestureEnabler: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navigationController, let top = nav.topViewController else { return false }
        return NativePopPolicy.shouldBegin(
            isAtRoot: nav.viewControllers.count <= 1,
            isTransitioning: nav.transitionCoordinator != nil,
            hidesBackButton: top.navigationItem.hidesBackButton,
            ownsInteractiveDismissal: (top as? any ZoomTransitionDestination)?.zoomOwnsInteractiveDismissal,
            hasCustomLeadingItem: top.navigationItem.leftBarButtonItem != nil,
            leadingItemsSupplementBackButton: top.navigationItem.leftItemsSupplementBackButton
        )
    }
}
