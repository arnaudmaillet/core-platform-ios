import MediaCore
import CoreModels
import CoreNavigation
import FeedInterface
import MediaPlayback
import UIKit

/// The feed feature's entry point, resolved by the composition root and
/// consumed through `FeedFeatureBuilding` by the app shell.
@MainActor
public struct FeedFeatureBuilder: FeedFeatureBuilding {
    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let commentsProvider: (any CommentsProviding)?
    private let realtime: (any FeedRealtimeSubscribing)?
    private let composedPosts: ComposedPostChannel?
    private let router: (any Router)?
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController?

    public init(
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        commentsProvider: (any CommentsProviding)? = nil,
        realtime: (any FeedRealtimeSubscribing)? = nil,
        composedPosts: ComposedPostChannel? = nil,
        router: (any Router)? = nil,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil
    ) {
        self.repository = repository
        self.engagementProvider = engagementProvider
        self.commentsProvider = commentsProvider
        self.realtime = realtime
        self.composedPosts = composedPosts
        self.router = router
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
    }

    /// The timeline is the full-screen snap feed — the app's sole Timeline.
    public func makeFeedViewController() -> UIViewController {
        SnapFeedViewController(
            viewModel: FeedViewModel(
                repository: repository,
                engagementProvider: engagementProvider,
                realtime: realtime,
                composedPosts: composedPosts,
                router: router
            ),
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback
        )
    }

    public func makeSnapFeedViewController(postIDs: [PostID]) -> UIViewController {
        SnapFeedViewController(
            viewModel: FeedViewModel(
                repository: FixedPostsFeedProvider(base: repository, ids: postIDs),
                engagementProvider: engagementProvider,
                router: router
            ),
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback
        )
    }

    public func makePostDetailViewController(for postID: PostID, mode: PostDetailMode) -> UIViewController {
        PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: postID,
                repository: repository,
                engagementProvider: engagementProvider,
                commentsProvider: commentsProvider,
                router: router
            ),
            imagePipeline: imagePipeline,
            mode: mode
        )
    }
}
