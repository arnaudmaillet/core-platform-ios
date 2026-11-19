import Connect
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreRealtime
import CoreStorage
import DesignSystem
import EntityStore
import Feed
import FeedInterface
import Foundation
import LocalStore
import MediaCore
import ProfileData
import Search
import SearchInterface
import UIKit

// Search (#2375): the search screen's repositories and builder, and the
// composers' completions. Its properties are declared in `AppContainer.swift`,
// since an extension holds no stored property; they are built here.
extension AppContainer {
    func makeSearchRepository() -> SearchRepository {
        SearchRepository(
            searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient)
        )
    }

    func makeTextCompletions() -> any TextCompletionProviding {
        TextCompletionService(
            searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient)
        )
    }

    func makeExploreRepository() -> DiscoverExploreAdapter {
        DiscoverExploreAdapter(
            repository: DiscoverRepository(
                feed: feedRepository,
                postCounters: postCounters,
                discovery: discoveryRepository
            )
        )
    }

    /// Pictures and social context for the search screen's person rows.
    /// `search.v1` answers with storage keys and no relationship at all, and
    /// `Suggest` with neither — so `profile.v1` and `social_graph.v1` are the
    /// only reads that carry them. See `ProfileMetadataRepository` for the
    /// fan-out this bounds.
    ///
    /// Not a `lazy var`: the viewer closure captures an actor, and a stored
    /// property's initializer cannot be both main-actor and actor isolated
    /// under Swift 6.2's default-isolation rule. A computed body can — the same
    /// shape `realtimeClient` above uses, for the same diagnostic.
    var profileMetadataRepository: ProfileMetadataRepository {
        if let cachedProfileMetadataRepository { return cachedProfileMetadataRepository }
        let profiles = profileRepository
        let repository = ProfileMetadataRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
            // The relation is asked from the VIEWER's side, so it needs whose
            // side that is; nil before sign-in simply means no context on the
            // rows rather than a wrong one.
            viewerID: { await profiles.viewerProfileID() },
            people: entityStore
        )
        // A follow accepted on any screen reaches the search rows' session
        // cache (#896), as it reaches the profile header and the feed's "+".
        profileMetadataFollowSubscription = followGraphEvents.subscribe { change in
            Task { await repository.applyFollowChange(change) }
        }
        cachedProfileMetadataRepository = repository
        return repository
    }

    func makeSearchFeature() -> any SearchFeatureBuilding {
        SearchFeatureBuilder(
            repository: searchRepository,
            recentSearches: recentSearchStore,
            explore: exploreRepository,
            metadata: profileMetadataRepository,
            imagePipeline: imagePipeline,
            router: routeResolver,
            // The results screen's Posts and Media tabs, from Feed — joined HERE
            // rather than by a dependency, exactly as `explore:` above is. See
            // `SearchPostSurfaceAdapter`.
            postSurfaces: SearchPostSurfaceAdapter(feed: feedFeature),
            // The balance in the results header. The STORE is shared — one wallet,
            // one claim countdown — and the sheet is the shell's, so it crosses as
            // a closure. Same wiring as the two pushed hosts in Feed.
            wallet: walletStore,
            makeWalletSheet: { [unowned self] in self.makeWalletSheet() },
            showsBalance: { [unowned self] in self.memberGate.isMember },
            // The trending people, so a cold start opens Search on them (#893).
            localStore: localStore,
            // The person rows hear a follow made on any screen (#896).
            followEvents: followGraphEvents,
            presence: sectionPresence,
            viewerEvents: viewerEvents
        )
    }
}
