import CoreNavigation
import NotificationsInterface
import ProfileInterface
import UIKit

/// The authenticated app shell: a `UITabBarController` composed of one child
/// `TabCoordinator` per tab. Each tab owns its own navigation stack; this
/// coordinator only assembles them and holds them alive.
///
/// Tabs are set via the modern `UITabBarController.tabs` API. The Search tab is
/// a `UISearchTab`, which the system detaches to the trailing edge, producing
/// the grouped bar `| Maps  Feed  Messages |  Search |` natively.
///
/// Profile is not a tab: it opens as a sheet from the avatar button in the
/// Maps nav bar (see `ProfileFlowCoordinator`), and the unread-notifications
/// badge the Profile tab used to carry lives on that avatar as a dot.
@MainActor
final class MainTabCoordinator: NSObject, Coordinator {
    var childCoordinators: [Coordinator] = []
    let tabBarController = UITabBarController()

    private let container: AppContainer
    private let onLogout: () -> Void
    private let avatarButton = ProfileAvatarButton()
    private var profileFlow: ProfileFlowCoordinator?
    /// Tabs paired with their `AppTab`, in bar order — the lookup `selectTab`
    /// and the `-select-tab` debug hook resolve against.
    private var orderedTabs: [(AppTab, any TabCoordinator)] = []

    init(container: AppContainer, onLogout: @escaping () -> Void) {
        self.container = container
        self.onLogout = onLogout
        super.init()
    }

    func start() {
        let profileFlow = ProfileFlowCoordinator(
            container: container,
            onLogout: onLogout,
            onDismiss: { [weak self] in self?.refreshUnreadDot() }
        )
        addChild(profileFlow)
        self.profileFlow = profileFlow

        avatarButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.profileFlow?.present(from: tabBarController)
            },
            for: .touchUpInside
        )

        orderedTabs = [
            (.maps, MapsTabCoordinator(container: container, profileButtonItem: UIBarButtonItem(customView: avatarButton))),
            (.feed, FeedTabCoordinator(container: container)),
            (.messages, MessagesTabCoordinator(container: container)),
            (.search, SearchTabCoordinator(container: container))
        ]
        for (_, tab) in orderedTabs {
            tab.start()
            addChild(tab)
        }
        tabBarController.tabs = orderedTabs.map { $0.1.tab }
        tabBarController.delegate = self

        loadAvatar()
        refreshUnreadDot()

        #if DEBUG
        // Dev convenience: `-select-tab N` opens directly on a tab for testing
        // (0 = Maps … 3 = Search).
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-select-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), orderedTabs.indices.contains(tabIndex) {
            tabBarController.selectedTab = orderedTabs[tabIndex].1.tab
        }
        // `-open-my-profile` presents the profile sheet on launch — the avatar
        // tap's code path — so the sheet flow is testable without driving the
        // UI. Deferred a tick: at `start()` the shell isn't the window root yet.
        if arguments.contains("-open-my-profile") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.profileFlow?.present(from: tabBarController)
            }
        }
        #endif
    }

    /// Resolves the viewer's avatar into the button; the placeholder glyph
    /// stays if there is none (or it can't be fetched).
    private func loadAvatar() {
        Task { [weak self] in
            guard let self else { return }
            let image = await container.profileFeature.viewerAvatarImage()
            avatarButton.setAvatar(image)
        }
    }

    /// Mirrors the unread notifications count onto the avatar's dot. Best-effort
    /// and idempotent — called on start, on every tab switch, and when the
    /// profile sheet (which hosts the notifications feed) is dismissed.
    private func refreshUnreadDot() {
        Task { [weak self] in
            guard let self else { return }
            let count = await container.notificationsFeature.unreadCount()
            avatarButton.setHasUnread(count > 0)
        }
    }
}

// MARK: - Badge refresh

extension MainTabCoordinator: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        refreshUnreadDot()
    }
}

// MARK: - AppNavigating

extension MainTabCoordinator: AppNavigating {
    var activeNavigationController: UINavigationController? {
        // Resolve through the presented chain (profile sheet, snap feed, compose)
        // so a route fired from a presented surface lands *on* that surface,
        // not invisibly under it on the covered tab stack.
        var top: UIViewController = tabBarController
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        if top === tabBarController {
            return tabBarController.selectedViewController as? UINavigationController
        }
        return top as? UINavigationController ?? top.navigationController
    }

    func selectTab(_ tab: AppTab) {
        guard let match = orderedTabs.first(where: { $0.0 == tab }) else { return }
        // Tab-owning routes mean "take me there": anything presented over the
        // shell would keep covering the destination, so dismiss it first.
        if tabBarController.presentedViewController != nil {
            tabBarController.dismiss(animated: true)
        }
        tabBarController.selectedTab = match.1.tab
    }
}
