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
    private let presentation: FeedPresentationStyle

    public init(
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        commentsProvider: (any CommentsProviding)? = nil,
        realtime: (any FeedRealtimeSubscribing)? = nil,
        composedPosts: ComposedPostChannel? = nil,
        router: (any Router)? = nil,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        presentation: FeedPresentationStyle = .classic
    ) {
        self.repository = repository
        self.engagementProvider = engagementProvider
        self.commentsProvider = commentsProvider
        self.realtime = realtime
        self.composedPosts = composedPosts
        self.router = router
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.presentation = presentation
    }

    public func makeFeedViewController() -> UIViewController {
        let viewModel = FeedViewModel(
            repository: repository,
            engagementProvider: engagementProvider,
            realtime: realtime,
            composedPosts: composedPosts,
            router: router
        )
        switch presentation {
        case .classic:
            return FeedViewController(viewModel: viewModel, imagePipeline: imagePipeline)
        case .snap:
            return SnapFeedViewController(
                viewModel: viewModel,
                imagePipeline: imagePipeline,
                videoPlayback: videoPlayback
            )
        }
    }

    public func makePostDetailViewController(for postID: PostID) -> UIViewController {
        PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: postID,
                repository: repository,
                engagementProvider: engagementProvider,
                commentsProvider: commentsProvider,
                router: router
            ),
            imagePipeline: imagePipeline
        )
    }
}
