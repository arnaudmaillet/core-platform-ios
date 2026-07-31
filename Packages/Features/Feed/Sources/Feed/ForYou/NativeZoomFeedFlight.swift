import UIKit

/// Navigation delegate for a For You → Snap Feed flight run by **UIKit's own**
/// zoom transition (`preferredTransition = .zoom`), behind `-native-zoom`.
/// Issue #83, step 1b.
///
/// It vends no animators and owns no card: the system morphs live
/// `CAPortalLayer` mirrors of the real view trees, so nothing is re-parented,
/// nothing is snapshotted, and no surface has to be hoisted, donated or held.
///
/// What it does own is the **player handoff**, which the system knows nothing
/// about, at the three moments a navigation transition exposes:
///
/// - **staging** (`willShow`, *before* the flight): the feed parks its player
///   and the landing tile takes it, so the tile is already rendering live when
///   the morph crossfades to it ~100ms in. Doing this at completion instead is
///   precisely the thumbnail flash issue #83 exists to remove.
/// - **cancellation**: the system's interactive dismissal can be abandoned, and
///   the page that stays up has to take its player back.
/// - **return** (`didShow`): the grid closes its handoff scope and reconciles.
///
/// Retained by the presenter for the length of the flight — a navigation
/// controller holds its delegate weakly.
@MainActor
final class NativeZoomFeedFlight: NSObject, UINavigationControllerDelegate {
    private weak var feed: UIViewController?
    private let onDismissalStaged: () -> Void
    private let onDismissalCancelled: () -> Void
    private let onReturned: () -> Void

    /// `willShow` fires for pushes above the feed too (the comments detail), and
    /// a cancelled interactive dismissal re-arms it. Staging twice would park a
    /// player that is already parked.
    private var hasStagedDismissal = false

    init(
        feed: UIViewController,
        onDismissalStaged: @escaping () -> Void,
        onDismissalCancelled: @escaping () -> Void,
        onReturned: @escaping () -> Void
    ) {
        self.feed = feed
        self.onDismissalStaged = onDismissalStaged
        self.onDismissalCancelled = onDismissalCancelled
        self.onReturned = onReturned
        super.init()
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        // The feed is leaving the stack. Fires for the back button and for the
        // system's interactive dismissal alike, and — unlike `didShow` — before
        // the flight, which is the whole point.
        guard !hasStagedDismissal, let feed,
              viewController !== feed,
              !navigationController.viewControllers.contains(feed)
        else { return }
        hasStagedDismissal = true
        onDismissalStaged()

        navigationController.transitionCoordinator?.notifyWhenInteractionChanges { [weak self] context in
            MainActor.assumeIsolated {
                guard context.isCancelled else { return }
                self?.hasStagedDismissal = false
                self?.onDismissalCancelled()
            }
        }
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        // Only a COMPLETED departure reports: a cancelled dismissal shows the
        // feed again and is handled by the interaction hook above; a detail
        // pushed over the feed keeps it on the stack and reports nothing.
        guard let feed else {
            onReturned()
            return
        }
        guard viewController !== feed,
              !navigationController.viewControllers.contains(feed)
        else { return }
        onReturned()
    }
}
