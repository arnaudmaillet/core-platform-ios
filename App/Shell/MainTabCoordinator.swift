import CoreNavigation
import NotificationsInterface
import ProfileInterface
import UIKit
#if DEBUG
import UploadInterface
#endif

/// The authenticated app shell: a `UITabBarController` composed of one child
/// `TabCoordinator` per tab. Each tab owns its own navigation stack; this
/// coordinator only assembles them and holds them alive.
///
/// Tabs are set via the modern `UITabBarController.tabs` API. The Search tab is
/// a `UISearchTab`, which the system detaches to the trailing edge, producing
/// the grouped bar `| Maps  Feed  Messages |  Search |` natively.
///
/// Two bar buttons are not tabs. Profile opens as a sheet from the avatar
/// button in the Maps nav bar (see `ProfileFlowCoordinator`), and the
/// unread-notifications badge the Profile tab used to carry lives on that
/// avatar as a dot. Feed keeps its bar button, but selecting it is vetoed
/// (`shouldSelectTab`) and the timeline is *pushed* onto the current tab's
/// stack instead (see `FeedFlowCoordinator`) — back returns to where the user
/// was, and no tab switch occurs.
@MainActor
final class MainTabCoordinator: NSObject, Coordinator {
    var childCoordinators: [Coordinator] = []
    let tabBarController = UITabBarController()

    private let container: AppContainer
    private let onLogout: () -> Void
    private let avatarButton = ProfileAvatarButton()
    private var profileFlow: ProfileFlowCoordinator?
    private var feedFlow: FeedFlowCoordinator?
    /// Tabs paired with their `AppTab`, in bar order — the lookup `selectTab`
    /// resolves against. Feed is absent: it contributes `feedActionTab` to the
    /// bar but owns no root stack.
    private var orderedTabs: [(AppTab, any TabCoordinator)] = []

    /// The Feed bar button. The provider must vend *something* — and the
    /// system calls it eagerly when `tabs` is assigned, not on first selection
    /// — but selection is always vetoed in `shouldSelectTab`, so the
    /// placeholder is only ever *shown* if a programmatic path sets
    /// `selectedTab` to it: a bug, made visible (and recoverable via its
    /// button) rather than a black screen.
    private lazy var feedActionTab = UITab(
        title: "Feed",
        image: UIImage(systemName: "house"),
        identifier: AppTab.feed.rawValue
    ) { [weak self] _ in
        PlaceholderViewController(
            title: "Feed",
            systemImage: "house",
            message: "The Feed opens as a pushed screen.",
            actionTitle: "Open Feed",
            action: { self?.openFeed() }
        )
    }

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

        let feedFlow = FeedFlowCoordinator(container: container)
        feedFlow.start()
        addChild(feedFlow)
        self.feedFlow = feedFlow

        orderedTabs = [
            (.maps, MapsTabCoordinator(container: container, profileButtonItem: UIBarButtonItem(customView: avatarButton))),
            (.messages, MessagesTabCoordinator(container: container)),
            (.search, SearchTabCoordinator(container: container))
        ]
        for (_, tab) in orderedTabs {
            tab.start()
            addChild(tab)
        }
        // Feed rides the bar at its usual slot but is not in `orderedTabs`:
        // it has no root stack to select, only a push to trigger.
        var tabs = orderedTabs.map { $0.1.tab }
        tabs.insert(feedActionTab, at: 1)
        tabBarController.tabs = tabs
        tabBarController.delegate = self

        loadAvatar()
        refreshUnreadDot()

        #if DEBUG
        // Dev convenience: `-select-tab N` opens directly on a tab for testing,
        // in bar order (0 = Maps … 3 = Search). 1 (Feed) is not a selection:
        // it triggers the push, deferred a tick — at `start()` the shell isn't
        // the window root yet, so an immediate push would animate off-window.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-select-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), AppTab.allCases.indices.contains(tabIndex) {
            let tab = AppTab.allCases[tabIndex]
            if tab == .feed {
                DispatchQueue.main.async { [weak self] in self?.openFeed() }
            } else {
                selectTab(tab)
            }
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
        // `-present-compose` presents the compose sheet on launch, for
        // driving/screenshotting compose without tapping through the UI.
        // Presented over the shell: the feed's bar no longer carries a compose
        // item (its chrome is identical across both entry paths), so this is
        // the `.upload` route's presentation, not a feed affordance. Deferred
        // a tick: at `start()` the shell isn't the window root yet.
        if arguments.contains("-present-compose") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                tabBarController.present(container.uploadFeature.makeComposeViewController(), animated: true)
            }
        }
        // `-feed-repush-demo` pushes the feed twice (combine with
        // `-snap-auto-dismiss`, which pops it ~2.5s after each landing): the
        // second push must resume where the first left off — the retained-
        // timeline continuity the sim can't demonstrate by tapping.
        if arguments.contains("-feed-repush-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openFeed() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in self?.openFeed() }
        }
        // `-feed-swipe-demo` pushes the feed, then drives the swipe-to-pop
        // twice: below the completion threshold (springs back), then past it
        // (pops home, bar returns) — the sim can't inject pans.
        if arguments.contains("-feed-swipe-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openFeed() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.feedFlow?.debugScriptedSwipe()
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

// MARK: - Tab selection

extension MainTabCoordinator: UITabBarControllerDelegate {
    /// The Feed button is an action, not a place: veto its selection (the
    /// current tab stays selected, its stack stays put) and push the timeline
    /// onto that stack instead.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab.identifier == AppTab.feed.rawValue else { return true }
        openFeed()
        // Vetoed selections never reach `didSelect`; refresh the dot here so a
        // Feed tap keeps the same badge freshness a tab switch has.
        refreshUnreadDot()
        return false
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        refreshUnreadDot()
        syncTabBarVisibility()
    }

    /// The bar is managed by hand around full-bleed snap surfaces (the pushed
    /// timeline and the pin-opened feed both hide it), and manual state is
    /// global to the shell's one bar — so a tab switch must reconcile it with
    /// whatever the newly selected tab has on top: hidden over a snap
    /// surface, visible otherwise.
    private func syncTabBarVisibility() {
        let top = (tabBarController.selectedViewController as? UINavigationController)?.topViewController
        tabBarController.setTabBarHidden(top is any ZoomTransitionDestination, animated: false)
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
        // Feed is not a selectable tab; honor the intent as the push it now is.
        if tab == .feed {
            openFeed()
            return
        }
        guard let match = orderedTabs.first(where: { $0.0 == tab }) else { return }
        // Tab-owning routes mean "take me there": anything presented over the
        // shell would keep covering the destination, so dismiss it first.
        if tabBarController.presentedViewController != nil {
            tabBarController.dismiss(animated: true)
        }
        tabBarController.selectedTab = match.1.tab
        // Programmatic selection skips `didSelect` — reconcile the bar here.
        syncTabBarVisibility()
    }

    func openFeed() {
        // "Take me to the feed" — from a bar tap, a deep link, or a push
        // payload: anything presented over the shell would cover the pushed
        // timeline, so dismiss it first, then push onto the selected tab's
        // stack. No tab switch: back returns exactly to where the user was.
        if tabBarController.presentedViewController != nil {
            tabBarController.dismiss(animated: true)
        }
        guard let navigationController = tabBarController.selectedViewController as? UINavigationController else { return }
        feedFlow?.push(on: navigationController)
    }
}
