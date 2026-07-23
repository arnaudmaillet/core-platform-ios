import CoreModels
import FeedInterface
import MapsInterface
import MediaCore
import MediaPlayback
import UIKit

/// The Maps feature's entry point, resolved by the composition root and
/// consumed through `MapsFeatureBuilding` by the app shell.
@MainActor
public struct MapsFeatureBuilder: MapsFeatureBuilding {
    private let repository: any GeoDiscoveryProviding
    private let favoritesRepository: any MapFavoritesProviding
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController
    private let feedFeature: () -> any FeedFeatureBuilding
    private let openProfile: (ProfileID, ProfileIdentityStub?) -> Void
    private let openConversation: (ProfileID) -> Void

    /// - Parameters:
    ///   - videoPlayback: a Maps-dedicated player pool (separate from the feed's)
    ///     for the live pin previews, so the two surfaces never contend.
    ///   - feedFeature: resolves the feed builder lazily, so the map can expand a
    ///     pin/cluster into the shared snap feed without the composition root
    ///     ordering the two features.
    ///   - openProfile: fires the app's profile destination for a person the map
    ///     surfaces (the sub-filter sheet's Profile swipe). Injected rather than
    ///     imported so Maps keeps knowing nothing about routes or the Profile
    ///     feature.
    ///   - openConversation: fires the app's message-this-person destination
    ///     (the sub-filter pill menu's Send Message). Injected for the same
    ///     reason as `openProfile`.
    public init(
        repository: any GeoDiscoveryProviding,
        favoritesRepository: any MapFavoritesProviding,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController,
        feedFeature: @escaping () -> any FeedFeatureBuilding,
        openProfile: @escaping (ProfileID, ProfileIdentityStub?) -> Void,
        openConversation: @escaping (ProfileID) -> Void
    ) {
        self.repository = repository
        self.favoritesRepository = favoritesRepository
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.feedFeature = feedFeature
        self.openProfile = openProfile
        self.openConversation = openConversation
    }

    public func makeMapViewController() -> UIViewController {
        let feedFeature = feedFeature
        return MapsViewController(
            viewModel: MapsViewModel(repository: repository),
            favoritesRepository: favoritesRepository,
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            makeSnapFeed: { postIDs in feedFeature().makeSnapFeedViewController(postIDs: postIDs) },
            prewarm: { ids in await feedFeature().prewarmPosts(ids) },
            openProfile: openProfile,
            openConversation: openConversation
        )
    }
}
