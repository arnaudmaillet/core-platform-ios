import Connect
import CoreContracts
import CoreModels
import CoreNavigation
import CoreStorage
import EntityStore
import Feed
import Foundation
import MediaCore
import MediaPlayback
import Place
import PlaceInterface
import UIKit

// Place (#2375): the place page. Its properties are declared in
// `AppContainer.swift`, since an extension holds no stored property; they are
// built here.
extension AppContainer {
    func makePlaceFeature() -> any PlaceFeatureBuilding {
        PlaceFeatureBuilder(
            feed: feedBuilder,
            hydrate: { [feedBuilder] ids in try await feedBuilder.placeGalleryPosts(ids) },
            // A place page pages the place's posts past the map's pins (#643).
            placePosts: PlacePostsRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: authenticatedRPCClient)),
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            // The same balance the map's toolbar shows under the page, and the
            // same sheet: one wallet instance app-wide.
            wallet: walletStore,
            makeWalletSheet: { [unowned self] in self.makeWalletSheet() },
            showsBalance: { [unowned self] in self.memberGate.isMember },
            entities: entityStore,
            router: routeResolver,
            authorMarks: feedBuilder.authorMarks,
            postOpenWarm: feedBuilder.postOpenWarm,
            presence: sectionPresence
        )
    }
}
