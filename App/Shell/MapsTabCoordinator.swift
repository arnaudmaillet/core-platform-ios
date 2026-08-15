import CoreNavigation
import CoreStorage
import DesignSystem
import MapsInterface
import UIKit

/// Owns the Maps tab: the map surface vended by the Maps feature behind the
/// `MapsFeatureBuilding` seam, on its own navigation stack (Step B pushes/
/// presents the vertical snap feed here).
@MainActor
final class MapsTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer
    private let notificationsButtonItem: UIBarButtonItem

    private(set) lazy var tab = UITab(
        title: "Maps",
        image: UIImage(systemName: "map"),
        identifier: AppTab.maps.rawValue
    ) { [navigationController] _ in navigationController }

    /// The post-creation entry point: a top-left "+" that opens the compose
    /// flow. Stateless (unlike the avatar, which carries image + unread state,
    /// so the shell injects it) — the tap just fires the `.upload` route, which
    /// the resolver presents as the compose sheet. Constructed here so the tap
    /// is owned by the coordinator, not the map surface; the Maps package stays
    /// navigation-agnostic. iOS 26 renders bar items in a glass bubble natively,
    /// so no custom chrome is needed to match the header aesthetic.
    private lazy var createPostButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                self?.container.router.route(to: .upload)
            }
        )
        item.accessibilityLabel = "Create Post"
        return item
    }()

    /// The wallet's toolbar face: coin + balance, pulsing while a claim
    /// waits. A custom view (an image item can't carry the count), hosted on
    /// an item that KEEPS ITS OWN CAPSULE — iOS 26 draws one shared glass
    /// background behind adjacent bar items, and without the opt-out the
    /// badge and the bell fuse into a single pill (`LeadingSelectorItem`'s
    /// doctrine, applied trailing-side).
    private lazy var walletBadge = WalletBadgeButton()
    private lazy var walletBadgeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(customView: walletBadge)
        item.sharesBackground = false
        return item
    }()
    /// Wakes the badge when the hourly claim unlocks — the one state change
    /// that arrives by CLOCK, not by store mutation, so no notification will
    /// ever announce it. One-shot, re-armed from every refresh.
    private var claimUnlockTimer: Timer?
    /// The store-change half of the badge's freshness (spends and claims,
    /// wherever they happen). Held for the coordinator's lifetime — the tab
    /// coordinators live exactly as long as the process.
    private var walletObserver: NSObjectProtocol?
    /// The screen wearing the bar items, for the width-change reinstall
    /// (a bar measures a custom view once, at install — see
    /// `WalletBadgeButton.onFittedWidthChange`).
    private weak var mapViewController: UIViewController?

    init(container: AppContainer, notificationsButtonItem: UIBarButtonItem) {
        self.container = container
        self.notificationsButtonItem = notificationsButtonItem
    }

    func start() {
        let mapViewController = container.mapsFeature.makeMapViewController()
        self.mapViewController = mapViewController
        // The Notifications (bell) entry point lives here — and only here: a
        // navigationItem belongs to this one view controller, so no other tab
        // can show it and nothing needs conditional hiding. It is injected by
        // the shell (it carries unread state) so the Maps package stays
        // Notifications-agnostic.
        //
        // The avatar that used to sit to its right is gone: Profile is a root
        // tab now, and two entry points to one destination is one too many.
        // The wallet badge now stands where it stood — trailing group, inboard
        // of the bell ([coin] [bell]) — in its own glass bubble via
        // `sharesBackground = false` rather than the fixedSpace the avatar
        // era used.
        mapViewController.navigationItem.rightBarButtonItems = [notificationsButtonItem, walletBadgeItem]
        // The post-creation "+" sits opposite the pair, top-left.
        mapViewController.navigationItem.leftBarButtonItem = createPostButtonItem
        navigationController.viewControllers = [mapViewController]

        walletBadge.addAction(
            UIAction { [weak self] _ in self?.presentWalletSheet() },
            for: .primaryActionTriggered
        )
        // A grown count needs a re-measured wrapper, and the wrapper
        // belongs to the ITEM: re-assigning the same item hands the bar the
        // same wrapper with the same frozen size (measured in-sim — "120"
        // still wrapped). A FRESH item is the only thing the bar measures
        // anew.
        walletBadge.onFittedWidthChange = { [weak self] in
            guard let self, let nav = self.mapViewController?.navigationItem else { return }
            let fresh = UIBarButtonItem(customView: self.walletBadge)
            fresh.sharesBackground = false
            self.walletBadgeItem = fresh
            nav.rightBarButtonItems = [self.notificationsButtonItem, fresh]
        }
        walletObserver = NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification,
            object: container.walletStore,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWalletBadge() }
        }
        refreshWalletBadge()

        #if DEBUG
        // `-open-wallet`: presents the wallet sheet ~1s after launch — the
        // badge opens it on tap, which the sim can't deliver. Pair with
        // `-wallet-claim-ready` (claimable state) or `-wallet-demo-claim`
        // (fires the claim itself).
        if ProcessInfo.processInfo.arguments.contains("-open-wallet") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.presentWalletSheet()
            }
        }
        #endif
    }

    /// Renders one wallet snapshot onto the badge, and arms the wake-up for
    /// the moment the countdown ends.
    private func refreshWalletBadge() {
        let snapshot = container.walletStore.snapshot()
        walletBadge.update(
            balance: snapshot.balance,
            claimAvailable: snapshot.claimAvailable,
            claimProgress: snapshot.claimCountdown.map {
                WalletBadgeButton.ClaimProgress(fraction: $0.fraction, remaining: $0.remaining)
            }
        )

        claimUnlockTimer?.invalidate()
        claimUnlockTimer = nil
        guard let unlockAt = snapshot.nextClaimAt else { return }
        // +1s so the re-read lands strictly past the gate, never on it.
        let timer = Timer(
            fire: unlockAt.addingTimeInterval(1), interval: 0, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWalletBadge() }
        }
        RunLoop.main.add(timer, forMode: .common)
        claimUnlockTimer = timer
    }

    private func presentWalletSheet() {
        navigationController.present(
            WalletClaimViewController(wallet: container.walletStore),
            animated: true
        )
    }
}
