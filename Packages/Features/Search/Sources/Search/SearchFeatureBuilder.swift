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
    private let repository: any SearchProviding
    private let recentSearches: RecentSearchStore?
    private let explore: (any ExploreProviding)?
    private let metadata: (any ProfileMetadataProviding)?
    private let imagePipeline: ImagePipeline
    private let router: (any Router)?
    /// Where the results screen's Posts tab and the hashtag page come from. `nil` in a
    /// composition without Feed — see `SearchPostSurfaceProviding`.
    private let postSurfaces: (any SearchPostSurfaceProviding)?
    /// The viewer's point balance, for the results screen's header. `nil` in a
    /// composition without a wallet — the badge simply does not appear.
    private let wallet: WalletStore?
    /// The shell owns the claim sheet (`WalletClaimViewController` lives in
    /// App/Shell), so it arrives as a closure rather than a type.
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    /// The trending people on the device (#893), one for the app's lifetime:
    /// every search screen opens on the same stored list.
    private let localCache: SearchLocalCache?
    /// The app's follow channel: the person rows hear a follow made on any
    /// screen (#896). Nil: each row keeps the answer it read.
    private let followEvents: FollowGraphEvents?

    /// - Parameter localStore: the device store (#893): the resting screen's
    ///   trending people open on their last list at a cold start. Nil keeps
    ///   them in memory only.
    public init(
        repository: any SearchProviding,
        recentSearches: RecentSearchStore? = nil,
        explore: (any ExploreProviding)? = nil,
        metadata: (any ProfileMetadataProviding)? = nil,
        imagePipeline: ImagePipeline,
        router: (any Router)? = nil,
        postSurfaces: (any SearchPostSurfaceProviding)? = nil,
        wallet: WalletStore? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil,
        localStore: LocalStore? = nil,
        followEvents: FollowGraphEvents? = nil
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
        self.localCache = localStore.map(SearchLocalCache.init(store:))
        self.followEvents = followEvents
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
                followEvents: followEvents
            ),
            imagePipeline: imagePipeline,
            postSurfaces: postSurfaces,
            wallet: wallet,
            makeWalletSheet: makeWalletSheet
        )
    }

    public func makeHashtagViewController(tag: String) -> UIViewController {
        HashtagViewController(
            viewModel: HashtagViewModel(tag: tag, repository: repository),
            postSurfaces: postSurfaces
        )
    }
}
