import CoreNavigation
import LocalStore
import MediaCore
import NotificationsInterface
import UIKit

/// The notifications feature's entry point, resolved by the composition root and
/// consumed through `NotificationsFeatureBuilding` by the app shell.
@MainActor
public struct NotificationsFeatureBuilder: NotificationsFeatureBuilding {
    private let repository: any NotificationsProviding
    private let router: (any Router)?
    /// Draws the senders' pictures and the posts' stills. Optional: without
    /// it every row is complete with initials and no thumbnail.
    private let imagePipeline: ImagePipeline?
    /// The drawer's last 100 rows on the device (#897).
    private let deviceCache: NotificationsLocalCache?

    /// `localStore`: the drawer opens on its last rows, offline and at a cold
    /// start (#897). Nil keeps them in memory.
    public init(
        repository: any NotificationsProviding,
        router: (any Router)? = nil,
        imagePipeline: ImagePipeline? = nil,
        localStore: LocalStore? = nil
    ) {
        self.repository = repository
        self.router = router
        self.imagePipeline = imagePipeline
        self.deviceCache = localStore.map(NotificationsLocalCache.init(store:))
    }

    public func makeNotificationsViewController() -> UIViewController {
        let viewModel = NotificationsViewModel(repository: repository, router: router)
        viewModel.deviceCache = deviceCache
        return NotificationsViewController(viewModel: viewModel, imagePipeline: imagePipeline)
    }

    public func unreadCount() async -> Int {
        (try? await repository.unreadCount()) ?? 0
    }
}
