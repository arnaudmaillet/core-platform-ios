import ChatInterface
import CoreNavigation
import DesignSystem
import UIKit

/// Owns the Messages tab: the paged inbox (All / Requests / Suggestions),
/// promoted from a sub-screen of the feed to a primary root tab. Threads open
/// by pushing onto this tab's stack (or the current one, via routes).
@MainActor
final class MessagesTabCoordinator: TabCoordinator, GlyphTab {
    let glyph = TabGlyph.messages
    /// Whether a conversation is unread — the glyph's badge, no count (#1191).
    private(set) var hasUnread = false
    var onUnreadChange: (() -> Void)?

    private func setUnread(_ unread: Bool) {
        guard unread != hasUnread else { return }
        hasUnread = unread
        onUnreadChange?()
    }
    var childCoordinators: [Coordinator] = []
    let navigationController: UINavigationController = ArbitratedNavigationController()

    private let container: AppContainer
    /// The shell's bell, minted into this header's leading edge.
    private let notificationsBell: NotificationsBell
    // NO BALANCE HERE (#2336, the owner 2026-11-12): the likes balance shows
    // where likes are spent or earned, and the inbox has no heart, no spend
    // and no claim. This coordinator builds no `WalletBadgeInstaller`; the
    // badge's shared identifier lets UIKit take it out of the bar cleanly on
    // a switch from a tab that wears it.

    private(set) lazy var tab = UITab(
        title: "Messages",
        image: TabGlyph.messages.image(selected: false, badged: false),
        identifier: AppTab.messages.rawValue
    ) { [navigationController] _ in navigationController }

    private let onSignIn: () -> Void

    init(container: AppContainer, notificationsBell: NotificationsBell, onSignIn: @escaping () -> Void) {
        self.container = container
        self.notificationsBell = notificationsBell
        self.onSignIn = onSignIn
    }

    /// `TabCoordinator` conformance; the shell calls `show(member:)` instead.
    func start() {
        show(member: true)
    }

    /// Installs the root for this viewer, replacing the whole stack: the inbox
    /// for a member, the sign-in invitation for a guest (there is no inbox
    /// without an account, and nothing is loaded for one).
    func show(member: Bool) {
        guard member else {
            tab.badgeValue = nil
            setUnread(false)
            navigationController.viewControllers = [GuestSignInViewController(
                symbolName: "bubble.left.and.bubble.right",
                title: "Messages",
                message: "Sign up to message friends and see who wrote to you.",
                onSignIn: onSignIn
            )]
            return
        }
        // The inbox reports every tab's badge summed; the bar item wears it.
        // Nothing here counts anything — see
        // `MessagesInboxViewController.onTotalNewCountChange` for why the sum
        // is published from where its parts already are.
        let inbox = container.chatFeature.makeInboxViewController { [weak self] total in
            // No count on the bar (#1191): the badge variant of the glyph.
            self?.setUnread(total > 0)
        }
        navigationController.viewControllers = [inbox]
        // The header reads `[bell] …`, the search stacked under the bar — no
        // balance (#2336). The bell reaches the bar THROUGH the inbox rather
        // than onto its `navigationItem`, because the inbox rewrites its own
        // bar whenever search opens and closes — an item written from out here
        // would not survive the first search. The trailing accessory is left
        // empty.
        (inbox as? any HeaderAccessoryHosting)?
            .setLeadingAccessoryItem(notificationsBell.makeItem())
        // Loaded now, not on first appearance. The inbox's own reload happens
        // in `viewWillAppear`, which never fires on a launch that lands on
        // another tab — so without this the badge that exists to say "there is
        // something in Messages" is blank until Messages has been opened, which
        // is the one moment it has nothing left to tell anyone.
        container.chatFeature.primeInbox()
        // ⚠️ AND THE SCREEN THAT COUNTS IT (#748). The badge is the inbox
        // pages' sum, published from the inbox's `viewDidLoad` on: a tab never
        // opened never loaded its view, so the primed data sat uncounted and
        // the bar item stayed blank until Messages was selected. Loaded a beat
        // later, off the launch's first frame.
        DispatchQueue.main.async { [weak inbox] in inbox?.loadViewIfNeeded() }
    }
}
