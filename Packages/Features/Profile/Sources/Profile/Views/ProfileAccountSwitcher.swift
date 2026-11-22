import CoreModels
import CoreStorage
import UIKit

/// What the account switcher asks of its screen (#2522): the view model,
/// the header whose name opens it, the switcher's factory and the viewer's
/// channel.
@MainActor
protocol ProfileAccountSwitcherHost: UIViewController {
    var viewModel: ProfileViewModel { get }
    var headerView: ProfileHeaderView { get }
    var switcherFactory: ProfileSwitcherMenuFactory? { get }
    var viewerEvents: ViewerEvents? { get }
}

/// The own profile's account switcher, out of `ProfileViewController`
/// (#2522): the name that opens it, the switch heard from any switcher, and
/// the switch in flight the screen's render reads.
///
/// ⚠️ ARMED BEFORE THE SEED: `isSwitchingProfile` is set before `revalidate`,
/// and cleared by the screen's `onLoadSettled` (see `activeProfileSwitched`).
@MainActor
final class ProfileAccountSwitcher {
    private unowned let host: any ProfileAccountSwitcherHost

    init(host: any ProfileAccountSwitcherHost) {
        self.host = host
    }

    /// True between an account switch and the incoming profile landing. While
    /// set, the skeleton is withheld and updates cross-dissolve.
    var isSwitchingProfile = false
    /// The switch subscription, for this screen's lifetime: it ends with it.
    private var activeProfileSubscription: ViewerEventSubscription?

    /// Follows the active profile, from the screen's `viewDidLoad`.
    func subscribe() {
        // Kept on this screen, so it ends with it — no `deinit` to remember.
        activeProfileSubscription = host.viewerEvents?.onActiveProfileChange { [weak self] id in
            self?.activeProfileSwitched(to: id)
        }
    }

    /// The own profile's name opens the switcher (the screen's
    /// `configureNavigationBar`).
    func configureNameSwitcher() {
        // ⚠️ THE SWITCHER IS THE NAME'S, NOT THE BAR'S (the owner,
        // 2026-11-08): the own profile's name wears a chevron, and a tap on
        // it opens the app's one switcher (#2034), anchored to the name. The
        // switch itself is picked up through `viewerEvents`, so
        // this screen refreshes whichever switcher was used.
        if host.switcherFactory != nil {
            host.headerView.onTitleTapped = { [weak self] in self?.presentSwitcherFromName() }
            // Pre-load profiles, avatars and counts, so the switcher opens
            // complete on its first frame.
            reloadSwitcherMenu()
        }
    }

    /// The own profile's name was tapped: the switcher, from the name.
    private func presentSwitcherFromName() {
        host.switcherFactory?.present(
            from: .view(host.headerView.titleAnchor), over: host, includesAddProfile: true,
            onSwitch: {}, onAddProfile: { [weak self] in self?.presentAddProfilePlaceholder() }
        )
    }

    /// Pre-fetches the switcher snapshot and installs a synchronous menu on the
    /// switcher item. Re-run after a switch so the active marker updates.
    ///
    /// `onSwitch` is empty on purpose. Refreshing is driven by
    /// `viewerEvents` instead, so it happens no matter WHICH switcher
    /// was used — this screen's own, or the Profile tab's long-press menu, which
    /// is built by the shell and cannot call back into here.
    private func reloadSwitcherMenu() {
        guard let switcherFactory = host.switcherFactory else { return }
        Task { await switcherFactory.reload() }
    }

    /// The active profile changed — from any switcher anywhere.
    ///
    /// Refetches unconditionally, including on someone ELSE's profile: the
    /// viewer changed, so the follow state and relationship button this screen
    /// shows are now answers to a different question, not just the identity at
    /// the top.
    private func activeProfileSwitched(to profile: ProfileID) {
        // Cache-first: a profile already seen renders on THIS turn, and the
        // fetch behind it becomes a silent revalidation. A miss has nothing
        // truthful to show for the new identity, so it redacts rather than
        // leaving the previous profile's name and numbers on screen.
        // Armed BEFORE the seed: `revalidate` publishes cached content on this
        // same turn, so the stagger has to be in place already or the cached
        // profile snaps in. It is closed out by `onLoadSettled`, NOT by a
        // phase arriving — a revalidation that agrees with the cache publishes
        // no phase at all, and hanging the reset off one that may never come
        // is what stranded this screen in a skeleton.
        isSwitchingProfile = true
        if !host.viewModel.revalidate(after: profile) {
            // Nothing known about the new identity: bones are the honest state,
            // and their un-redact reveal is the animation — no stagger over it.
            isSwitchingProfile = false
            host.headerView.render(.loading, profileKnown: false, animated: false)
        }
        // Re-read the snapshot so the menu's active marker moves to the profile
        // just switched to.
        reloadSwitcherMenu()
    }

    private func presentAddProfilePlaceholder() {
        let alert = UIAlertController(
            title: "Add Profile",
            message: "Creating a new profile isn't available yet.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        host.present(alert, animated: true)
    }
}
