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
    /// Curating the people rail, shared with whatever else pins a profile —
    /// today the profile screen's pin button. Built here (not injected)
    /// because the state it owns is the map's own: no service vends a
    /// favorites list, so the device is the only place it has ever lived.
    /// Handed OUT through `profilePinning` so the composition root can give
    /// the same instance to another feature.
    private let pinService: MapProfilePinService
    /// The followed PLACES, built here for the same reason as `pinService`:
    /// no service vends them, so the device is where they live. One instance
    /// feeds both consumers — the gallery header's toggle and the map's
    /// Favorites sub-filter — which is what makes the toggle show up on the
    /// map at all.
    private let placeFollows = MapPlaceFollowStore()

    /// The interface-typed seam the composition root hands to other features.
    public var profilePinning: any MapProfilePinning { pinService }

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
        self.pinService = MapProfilePinService(
            store: MapFavoritesStore(), favorites: favoritesRepository
        )
    }

    public func makeMapViewController() -> UIViewController {
        let feedFeature = feedFeature
        let placeFollows = placeFollows
        return MapsViewController(
            viewModel: MapsViewModel(
                repository: repository,
                followedPlaceIDs: { placeFollows.followedPlaceIDs }
            ),
            favoritesRepository: favoritesRepository,
            pinService: pinService,
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            makeSnapFeed: { postIDs in feedFeature().makeSnapFeedViewController(postIDs: postIDs) },
            // The same feed, arrived at by the platform's own slide — what a
            // marker with no cover to fly opens with.
            pushPlainSnapFeed: { postIDs, presenter in
                feedFeature().pushSnapFeed(postIDs: postIDs, from: presenter)
            },
            // The place gallery a semantic cluster's feed dismisses into —
            // built by the Feed feature because the grid, the flight card and
            // the retarget wiring are all its internals.
            makeClusterGallery: { postIDs, place, feed in
                feedFeature().makeClusterGallery(
                    postIDs: postIDs,
                    title: place.galleryTitle,
                    // The header's follow toggle, bound to THIS place's
                    // identity in the map's own store — which is also what
                    // the Favorites sub-filter reads, so the button and the
                    // filter agree by construction.
                    following: ClusterGalleryFollowing(
                        isFollowing: { placeFollows.isFollowed(place.id) },
                        toggle: { placeFollows.toggle(place.id) }
                    ),
                    feed: feed
                )
            },
            prewarm: { ids in await feedFeature().prewarmPosts(ids) },
            openProfile: openProfile,
            openConversation: openConversation
        )
    }
}
