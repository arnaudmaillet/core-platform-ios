import CoreModels
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
    /// The mute toolbar offers pauses past 8 h and "until I turn it back on"
    /// (#1575): only where the server accepts them (the mock, until backend
    /// #971 reaches the fleet).
    private let allowsLongPushPauses: Bool
    /// The bar offers the trash (#1574): only where the server can clear
    /// (the mock, until backend #971 reaches the fleet).
    private let allowsClearAll: Bool
    /// Opens a post notification's post above the drawer (#1577); nil routes
    /// it.
    private let openPost: (@MainActor (NotificationPostOpening) -> Void)?

    /// `localStore`: the drawer opens on its last rows, offline and at a cold
    /// start (#897). Nil keeps them in memory.
    public init(
        repository: any NotificationsProviding,
        router: (any Router)? = nil,
        imagePipeline: ImagePipeline? = nil,
        localStore: LocalStore? = nil,
        allowsLongPushPauses: Bool = false,
        allowsClearAll: Bool = false,
        openPost: (@MainActor (NotificationPostOpening) -> Void)? = nil
    ) {
        self.allowsLongPushPauses = allowsLongPushPauses
        self.allowsClearAll = allowsClearAll
        self.openPost = openPost
        self.repository = repository
        self.router = router
        self.imagePipeline = imagePipeline
        self.deviceCache = localStore.map(NotificationsLocalCache.init(store:))
    }

    public func makeNotificationsViewController() -> UIViewController {
        let viewModel = NotificationsViewModel(repository: repository, router: router)
        viewModel.deviceCache = deviceCache
        return NotificationsViewController(
            viewModel: viewModel, imagePipeline: imagePipeline,
            muteModel: NotificationsMuteModel(repository: repository, allowsLongPauses: allowsLongPushPauses),
            offersClearAll: allowsClearAll,
            openPost: openPost
        )
    }

    public func unreadCount() async -> Int {
        (try? await repository.unreadCount()) ?? 0
    }

    public func unreadCount(forProfile profileID: String) async -> Int? {
        try? await repository.unreadCount(forProfile: ProfileID(profileID))
    }
}
