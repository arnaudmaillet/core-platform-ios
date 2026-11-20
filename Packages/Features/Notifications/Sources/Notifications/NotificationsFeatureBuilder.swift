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
    /// Everything the drawer needs, handed in by the composition root
    /// (#2375): each collaborator the app always wires is required, so
    /// forgetting one fails to compile.
    public struct Dependencies {
        /// The drawer's rows, their reads, mutes and unread counts.
        public var repository: any NotificationsProviding
        /// Where a row's tap goes.
        public var router: any Router
        /// Draws the senders' pictures and the posts' stills.
        public var imagePipeline: ImagePipeline
        /// The drawer opens on its last 100 rows, offline and at a cold start
        /// (#897). Nil when the device store can't be opened: the rows stay
        /// in memory.
        public var localStore: LocalStore?
        /// The mute toolbar offers pauses past 8 h and "until I turn it back
        /// on" (#1575): only where the server accepts them (the mock, until
        /// backend #971 reaches the fleet).
        public var allowsLongPushPauses: Bool
        /// The bar offers the trash (#1574): only where the server can clear
        /// (the mock, until backend #971 reaches the fleet).
        public var allowsClearAll: Bool
        /// Opens a post notification's post above the drawer (#1577).
        public var openPost: @MainActor (NotificationPostOpening) -> Void
        /// The app's viewer channel (#2376): the drawer empties and reloads
        /// for whoever is here now.
        public var viewerEvents: ViewerEvents

        public init(
            repository: any NotificationsProviding,
            router: any Router,
            imagePipeline: ImagePipeline,
            localStore: LocalStore?,
            allowsLongPushPauses: Bool,
            allowsClearAll: Bool,
            openPost: @escaping @MainActor (NotificationPostOpening) -> Void,
            viewerEvents: ViewerEvents
        ) {
            self.repository = repository
            self.router = router
            self.imagePipeline = imagePipeline
            self.localStore = localStore
            self.allowsLongPushPauses = allowsLongPushPauses
            self.allowsClearAll = allowsClearAll
            self.openPost = openPost
            self.viewerEvents = viewerEvents
        }
    }

    private let repository: any NotificationsProviding
    private let router: any Router
    private let imagePipeline: ImagePipeline
    /// The drawer's last 100 rows on the device (#897).
    private let deviceCache: NotificationsLocalCache?
    private let allowsLongPushPauses: Bool
    private let allowsClearAll: Bool
    private let openPost: @MainActor (NotificationPostOpening) -> Void
    private let viewerEvents: ViewerEvents

    public init(dependencies: Dependencies) {
        repository = dependencies.repository
        router = dependencies.router
        imagePipeline = dependencies.imagePipeline
        deviceCache = dependencies.localStore.map(NotificationsLocalCache.init(store:))
        allowsLongPushPauses = dependencies.allowsLongPushPauses
        allowsClearAll = dependencies.allowsClearAll
        openPost = dependencies.openPost
        viewerEvents = dependencies.viewerEvents
    }

    public func makeNotificationsViewController() -> UIViewController {
        let viewModel = NotificationsViewModel(repository: repository, router: router)
        viewModel.deviceCache = deviceCache
        viewModel.viewerEvents = viewerEvents
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
