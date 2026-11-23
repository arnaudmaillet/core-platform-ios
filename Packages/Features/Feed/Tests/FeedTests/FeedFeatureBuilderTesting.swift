import CoreModels
import CoreNavigation
import CoreStorage
import EntityStore
import MediaCore
import MediaPlayback
import PostSurfaces
@testable import Feed

/// A builder's dependencies for a test (#2375): what the test hands in, and
/// every optional collaborator left out — no engagement, comments (unless
/// handed), live updates, wallet, menus' rows, counters, sounds or Discover
/// pool; routes that go nowhere, a follow channel nobody posts on, a fresh
/// entity store unless handed one. What the builder did when the app's
/// collaborators were left out, before they were all named.
@MainActor
extension FeedFeatureBuilder.Dependencies {
    static func testing(
        repository: any FeedProviding,
        commentsProvider: (any CommentsProviding)? = nil,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        postDrafts: PostDraftStore,
        entities: (any EntityReading & EntityWriting)? = nil,
        bookmarks: PostBookmarkStore,
        viewHistory: PostViewHistoryStore,
        unavailablePosts: UnavailablePosts,
        savedSounds: SavedSoundStore,
        viewerProfile: @escaping @MainActor () -> ProfileID?
    ) -> Self {
        Self(
            repository: repository,
            engagementProvider: nil,
            commentsProvider: commentsProvider,
            realtime: nil,
            composedPosts: ComposedPostChannel(),
            router: InertFeedRouter(),
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            makeProfileSwitcher: { nil },
            wallet: nil,
            makeWalletSheet: nil,
            showsBalance: { true },
            reporting: nil,
            socialGraph: nil,
            followRelations: nil,
            followEvents: FollowGraphEvents(),
            postCounters: nil,
            postDrafts: postDrafts,
            soundProvider: nil,
            useSound: nil,
            discovery: nil,
            entities: entities ?? EntityStore(),
            shareTargeting: nil,
            bookmarks: bookmarks,
            viewHistory: viewHistory,
            unavailablePosts: unavailablePosts,
            savedSounds: savedSounds,
            viewerProfile: viewerProfile
        )
    }
}

private final class InertFeedRouter: Router {
    func route(to route: AppRoute) {}
}
