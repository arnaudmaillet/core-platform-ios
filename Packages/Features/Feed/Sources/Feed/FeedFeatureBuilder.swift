import CoreMedia
import CoreModels
import CoreNavigation
import FeedInterface
import UIKit

/// The feed feature's entry point, resolved by the composition root and
/// consumed through `FeedFeatureBuilding` by the app shell.
@MainActor
public struct FeedFeatureBuilder: FeedFeatureBuilding {
    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let realtime: (any FeedRealtimeSubscribing)?
    private let composedPosts: ComposedPostChannel?
    private let router: (any Router)?
    private let imagePipeline: ImagePipeline

    public init(
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        realtime: (any FeedRealtimeSubscribing)? = nil,
        composedPosts: ComposedPostChannel? = nil,
        router: (any Router)? = nil,
        imagePipeline: ImagePipeline
    ) {
        self.repository = repository
        self.engagementProvider = engagementProvider
        self.realtime = realtime
        self.composedPosts = composedPosts
        self.router = router
        self.imagePipeline = imagePipeline
    }

    public func makeFeedViewController() -> UIViewController {
        FeedViewController(
            viewModel: FeedViewModel(
                repository: repository,
                engagementProvider: engagementProvider,
                realtime: realtime,
                composedPosts: composedPosts,
                router: router
            ),
            imagePipeline: imagePipeline
        )
    }
}
