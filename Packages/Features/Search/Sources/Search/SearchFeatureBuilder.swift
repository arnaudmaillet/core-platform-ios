import CoreModels
import CoreNavigation
import CoreStorage
import LocalStore
import MediaCore
import SearchInterface
import UIKit

/// The search feature's entry point, resolved by the composition root and
/// consumed through `SearchFeatureBuilding` by the app shell.
@MainActor
public struct SearchFeatureBuilder: SearchFeatureBuilding {
    /// Everything search needs, handed in by the composition root (#2375):
    /// each collaborator the app always wires is required, so forgetting one
    /// fails to compile.
    public struct Dependencies {
        /// The queries' results: people, places, hashtags.
        public var repository: any SearchProviding
        /// The resting screen's recent searches.
        public var recentSearches: RecentSearchStore
        /// The resting screen's trending and suggested corpora.
        public var explore: any ExploreProviding
        /// The person rows' context (followers, the viewer's relation).
        public var metadata: any ProfileMetadataProviding
        public var imagePipeline: ImagePipeline
        /// Where a result's tap goes.
        public var router: any Router
        /// Where the results screen's Posts tab and the hashtag page come
        /// from: the feed's, joined by the composition root (see
        /// `SearchPostSurfaceProviding`).
        public var postSurfaces: any SearchPostSurfaceProviding
        /// The viewer's point balance, for the results screen's header.
        public var wallet: any WalletReading
        /// The shell owns the Wallet sheet (`WalletSheetViewController` lives
        /// in App/Shell), so it arrives as a closure rather than a type.
        public var makeWalletSheet: @MainActor () -> UIViewController
        /// Whether the results header wears the balance: not for a guest
        /// (#1146).
        public var showsBalance: @MainActor () -> Bool
        /// The device store (#893): the resting screen's trending people open
        /// on their last list at a cold start. Nil when the device store
        /// can't be opened: they stay in memory only.
        public var localStore: LocalStore?
        /// The app's follow channel: the person rows hear a follow made on
        /// any screen (#896).
        public var followEvents: FollowGraphEvents
        /// Whether the Suggested section had rows last time (#1773): the
        /// app's one store (#2376).
        public var presence: SectionPresenceStore
        /// The app's viewer channel (#2376): a search screen asks again for
        /// whoever is here now.
        public var viewerEvents: ViewerEvents

        public init(
            repository: any SearchProviding,
            recentSearches: RecentSearchStore,
            explore: any ExploreProviding,
            metadata: any ProfileMetadataProviding,
            imagePipeline: ImagePipeline,
            router: any Router,
            postSurfaces: any SearchPostSurfaceProviding,
            wallet: any WalletReading,
            makeWalletSheet: @escaping @MainActor () -> UIViewController,
            showsBalance: @escaping @MainActor () -> Bool,
            localStore: LocalStore?,
            followEvents: FollowGraphEvents,
            presence: SectionPresenceStore,
            viewerEvents: ViewerEvents
        ) {
            self.repository = repository
            self.recentSearches = recentSearches
            self.explore = explore
            self.metadata = metadata
            self.imagePipeline = imagePipeline
            self.router = router
            self.postSurfaces = postSurfaces
            self.wallet = wallet
            self.makeWalletSheet = makeWalletSheet
            self.showsBalance = showsBalance
            self.localStore = localStore
            self.followEvents = followEvents
            self.presence = presence
            self.viewerEvents = viewerEvents
        }
    }

    private let repository: any SearchProviding
    private let recentSearches: RecentSearchStore
    private let explore: any ExploreProviding
    private let metadata: any ProfileMetadataProviding
    private let imagePipeline: ImagePipeline
    private let router: any Router
    private let postSurfaces: any SearchPostSurfaceProviding
    private let wallet: any WalletReading
    private let makeWalletSheet: @MainActor () -> UIViewController
    private let showsBalance: @MainActor () -> Bool
    /// The trending people on the device (#893), one for the app's lifetime:
    /// every search screen opens on the same stored list.
    private let localCache: SearchLocalCache?
    private let followEvents: FollowGraphEvents
    private let presence: SectionPresenceStore
    private let viewerEvents: ViewerEvents

    public init(dependencies: Dependencies) {
        repository = dependencies.repository
        recentSearches = dependencies.recentSearches
        explore = dependencies.explore
        metadata = dependencies.metadata
        imagePipeline = dependencies.imagePipeline
        router = dependencies.router
        postSurfaces = dependencies.postSurfaces
        wallet = dependencies.wallet
        makeWalletSheet = dependencies.makeWalletSheet
        showsBalance = dependencies.showsBalance
        localCache = dependencies.localStore.map(SearchLocalCache.init(store:))
        followEvents = dependencies.followEvents
        presence = dependencies.presence
        viewerEvents = dependencies.viewerEvents
    }

    public func makeSearchViewController() -> UIViewController {
        SearchViewController(
            viewModel: SearchViewModel(
                repository: repository,
                router: router,
                recentSearches: recentSearches,
                explore: explore,
                metadata: metadata,
                localCache: localCache,
                followEvents: followEvents,
                viewerEvents: viewerEvents
            ),
            imagePipeline: imagePipeline,
            presence: presence,
            postSurfaces: postSurfaces,
            wallet: wallet,
            makeWalletSheet: makeWalletSheet,
            showsBalance: showsBalance
        )
    }

    public func makeHashtagViewController(tag: String) -> UIViewController {
        HashtagViewController(
            viewModel: HashtagViewModel(tag: tag, repository: repository, deviceCache: localCache),
            postSurfaces: postSurfaces
        )
    }
}
