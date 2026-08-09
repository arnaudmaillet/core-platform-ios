import CoreNavigation
import UIKit

/// Keeps the native edge-swipe-to-pop alive on a stack whose delegate slot is
/// sometimes occupied by a custom transition owner (`TimelineSlideDismissal`,
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
