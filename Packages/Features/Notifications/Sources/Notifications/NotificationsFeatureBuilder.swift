import CoreNavigation
import NotificationsInterface
import UIKit

/// The notifications feature's entry point, resolved by the composition root and
/// consumed through `NotificationsFeatureBuilding` by the app shell.
@MainActor
public struct NotificationsFeatureBuilder: NotificationsFeatureBuilding {
    private let repository: any NotificationsProviding
    private let router: (any Router)?

    public init(repository: any NotificationsProviding, router: (any Router)? = nil) {
        self.repository = repository
        self.router = router
    }

    public func makeNotificationsViewController() -> UIViewController {
        NotificationsViewController(
            viewModel: NotificationsViewModel(repository: repository, router: router)
        )
    }

    public func unreadCount() async -> Int {
        (try? await repository.unreadCount()) ?? 0
    }
}
