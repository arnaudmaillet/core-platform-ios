import CoreNavigation
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

    public init(
        repository: any NotificationsProviding,
        router: (any Router)? = nil,
        imagePipeline: ImagePipeline? = nil
    ) {
        self.repository = repository
        self.router = router
        self.imagePipeline = imagePipeline
    }

    public func makeNotificationsViewController() -> UIViewController {
        NotificationsViewController(
            viewModel: NotificationsViewModel(repository: repository, router: router),
            imagePipeline: imagePipeline
        )
    }

    public func unreadCount() async -> Int {
        (try? await repository.unreadCount()) ?? 0
    }
}
