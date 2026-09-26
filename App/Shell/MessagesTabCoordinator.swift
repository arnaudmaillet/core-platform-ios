import ChatInterface
import CoreNavigation
import UIKit

/// Owns the Messages tab: the paged inbox (All / Requests / Suggestions),
/// promoted from a sub-screen of the feed to a primary root tab. Threads open
/// by pushing onto this tab's stack (or the current one, via routes).
@MainActor
final class MessagesTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer
    /// The shell's bell, minted into this header's leading edge.
    private let notificationsBell: NotificationsBell
    /// The header's balance badge — the installer every root header wears.
    /// Held for the coordinator's life, which is the process's.
    private var walletBadge: WalletBadgeInstaller?

    private(set) lazy var tab = UITab(
        title: "Messages",
        image: UIImage(systemName: "message"),
        identifier: AppTab.messages.rawValue
    ) { [navigationController] _ in navigationController }

    init(container: AppContainer, notificationsBell: NotificationsBell) {
        self.container = container
        self.notificationsBell = notificationsBell
    }

    func start() {
        // The inbox reports every tab's badge summed; the bar item wears it.
        // Nothing here counts anything — see
        // `MessagesInboxViewController.onTotalNewCountChange` for why the sum
        // is published from where its parts already are.
        let inbox = container.chatFeature.makeInboxViewController { [weak self] total in
            self?.tab.badgeValue = total > 0 ? String(total) : nil
        }
        navigationController.viewControllers = [inbox]
        // The header reads `[bell] … [coins][search]`. Both items reach the bar
        // THROUGH the inbox rather than onto its `navigationItem`, because the
        // inbox rewrites its own bar whenever search opens and closes — an item
        // written from out here would not survive the first search.
        (inbox as? any HeaderAccessoryHosting)?
            .setLeadingAccessoryItem(notificationsBell.makeItem())
        walletBadge = WalletBadgeInstaller(
            wallet: container.walletStore,
            presenter: navigationController,
            makeSheet: { [unowned container] in container.makeWalletSheet() }
        ) { [weak inbox] item in
            (inbox as? any HeaderAccessoryHosting)?.setTrailingAccessoryItem(item)
        }
        // Loaded now, not on first appearance. The inbox's own reload happens
        // in `viewWillAppear`, which never fires on a launch that lands on
        // another tab — so without this the badge that exists to say "there is
        // something in Messages" is blank until Messages has been opened, which
        // is the one moment it has nothing left to tell anyone.
        container.chatFeature.primeInbox()
    }
}
