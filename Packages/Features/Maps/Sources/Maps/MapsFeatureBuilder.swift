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
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController
    private let feedFeature: () -> any FeedFeatureBuilding

    /// - Parameters:
    ///   - videoPlayback: a Maps-dedicated player pool (separate from the feed's)
    ///     for the live pin previews, so the two surfaces never contend.
    ///   - feedFeature: resolves the feed builder lazily, so the map can expand a
    ///     pin/cluster into the shared snap feed without the composition root
    ///     ordering the two features.
    public init(
        repository: any GeoDiscoveryProviding,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController,
        feedFeature: @escaping () -> any FeedFeatureBuilding
    ) {
        self.repository = repository
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.feedFeature = feedFeature
    }

    public func makeMapViewController() -> UIViewController {
        let feedFeature = feedFeature
        return MapsViewController(
            viewModel: MapsViewModel(repository: repository),
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            makeSnapFeed: { postIDs in feedFeature().makeSnapFeedViewController(postIDs: postIDs) },
            prewarm: { ids in await feedFeature().prewarmPosts(ids) }
        )
    }
}
