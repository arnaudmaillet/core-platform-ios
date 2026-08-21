import Auth
import AuthInterface
import Chat
import ChatInterface
import Connect
import CoreContracts
import CoreNavigation
import MediaCore
import CoreModels
import MediaPlayback
import CoreNetworking
import CoreNetworkingMocks
import CoreRealtime
import CoreRealtimeMocks
import CoreStorage
import Feed
import FeedInterface
import Foundation
import Maps
import MapsInterface
import Notifications
import NotificationsInterface
import Profile
import ProfileInterface
import Search
import SearchInterface
import Upload
import UploadInterface

/// Composition root. The only place concrete implementations are chosen and
/// wired; everything downstream receives protocols via initializer injection.
final class AppContainer {

    static let shared = AppContainer()

    private init() {}

    /// Selected by launch argument: `.mock` (default) or `.localFleet`.
    let environment = AppEnvironment.current

    /// The transport for Connect RPCs: the in-process mock, or the real
    /// URLSession client pointed at the Envoy gateway.
    private lazy var rpcHTTPClient: any HTTPClientInterface = {
        switch environment {
        case .mock: mockBackend.bff
        case .localFleet: URLSessionHTTPClient()
        }
    }()

    /// The whole in-process backend (dataset + stores + fully registered
    /// MockBFF), with network realism read from launch arguments
    /// (`-mock-latency`, `-mock-fail`, `-mock-fail-code`, `-mock-fail-rate`).
    private lazy var mockBackend = MockBackend(
        conditions: .fromLaunchArguments(),
        mediaCatalog: Self.usesRichMedia ? .realAssets : .synthetic
    )

    /// `-rich-media`: seed the mock dataset from `MockMediaFixtures` — real HLS
    /// ladders, progressive MP4s, and real photographs at exact dimensions —
    /// instead of the synthesized `mock://` assets.
    ///
    /// Opt-in on purpose. The default mock mode is offline and deterministic,
    /// which is what the unit suite and CI depend on; this flag trades that for
    /// realism (real decode cost, ABR, range requests) when driving the app by
    /// hand. It requires network.
    static let usesRichMedia = ProcessInfo.processInfo.arguments.contains("-rich-media")

    private(set) lazy var mockRealtimeServer = MockRealtimeServer()

    /// Bridge from the compose feature to the feed's optimistic insert.
    private let composedPostChannel = ComposedPostChannel()

    private lazy var unauthenticatedRPCClient = ConnectClientFactory.makeUnauthenticated(
        host: environment.host,
        wire: environment.wire,
        httpClient: rpcHTTPClient
    )

    /// RPC client for everything except AuthService; attaches the edge token
    /// and refreshes it single-flight.
    private(set) lazy var authenticatedRPCClient = ConnectClientFactory.makeAuthenticated(
        host: environment.host,
        tokenProvider: sessionManager,
        wire: environment.wire,
        httpClient: rpcHTTPClient
    )

    private(set) lazy var sessionManager = SessionManager(
        authClient: Auth_V1_AuthServiceClient(client: unauthenticatedRPCClient),
        store: KeychainSessionStore(store: KeychainStore(service: "cn.wynn.core-platform-ios")),
        configuration: .init(deviceID: Self.persistentDeviceID())
    )

    private(set) lazy var authFeature: any AuthFeatureBuilding = AuthFeatureBuilder(
        sessionManager: sessionManager
    )

    // MARK: - Media

    /// Mock mode renders deterministic placeholder images for `mock://` URLs;
    /// fleet mode fetches real images over HTTP, rewriting the fleet's
    /// Docker-internal minio host to the published one.
    private(set) lazy var imagePipeline: ImagePipeline = {
        let fetcher: any ImageFetching = switch environment {
        case .mock:
            // Scheme-routing, not plain placeholder: under `-rich-media` the
            // dataset mixes real `https://` photographs with synthesized
            // `mock://` assets, and each has to reach the right fetcher.
            SchemeRoutingImageFetcher()
        case .localFleet:
            URLSessionImageFetcher(hostRewrite: HostRewrite(from: "minio:9000", to: "localhost:9000"))
        }
        return ImagePipeline(fetcher: fetcher)
    }()

    /// Snap-feed video playback. Mock mode synthesizes deterministic clips for
    /// `mock://video/…` URLs; fleet mode passes delivery URLs straight to the
    /// player (a no-op today — the backend serves no video renditions yet).
    private(set) lazy var videoPlayback: VideoPlaybackController = {
        let source: any VideoSource = switch environment {
        case .mock: PlaceholderVideoFetcher()
        case .localFleet: PassthroughVideoSource()
        }
        return VideoPlaybackController(source: source)
    }()

    // MARK: - Realtime

    // Not `lazy var`: stored-property initializers can't call an
    // actor-isolated init under default-MainActor isolation (Swift 6.2
    // "default argument isolation" diagnostic); a computed body can.
    private var cachedRealtimeClient: RealtimeClient?
    var realtimeClient: RealtimeClient {
        if let cachedRealtimeClient {
            return cachedRealtimeClient
        }
        let sessionManager = sessionManager
        let transport: any RealtimeTransport = if let realtimeURL = environment.realtimeURL {
            URLSessionWebSocketTransport(url: realtimeURL)
        } else {
            mockRealtimeServer
        }
        let client = RealtimeClient(
            transport: transport,
            tokenProvider: { try await sessionManager.validAccessToken() },
            configuration: RealtimeClient.Configuration()
        )
        cachedRealtimeClient = client
        return client
    }

    #if DEBUG
    private var demoTicker: Task<Void, Never>?

    /// Demo driver for mock mode: bumps a like counter every couple of
    /// seconds and pushes it through the realtime plane, so live updates are
    /// visible on screen without a second user.
    func startMockRealtimeDemo() {
        guard demoTicker == nil else { return }
        let posts = mockBackend.dataset.posts.prefix(6).map(\.postID)
        let store = mockBackend.counterStore
        let server = mockRealtimeServer
        demoTicker = Task.detached {
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let postID = posts[index % posts.count]
                index += 1
                let next = store.incrementLikes(for: postID, by: Int64.random(in: 1...5))
                server.emitLikeCount(next, postID: postID)
            }
        }
    }
    #endif

    // MARK: - Wallet

    /// The viewer's point wallet — the client-side mock behind the currency
    /// badge, the claim sheet, and every boost button
    /// (`BACKEND_VIRTUAL_CURRENCY.md` is the ask for the real service).
    /// ONE instance, deliberately: `WalletStore`'s change notification is
    /// scoped to the instance that changed, so the map badge only hears
    /// about a feed spend because both surfaces hold this same object.
    private(set) lazy var walletStore = WalletStore()

    // MARK: - Feed

    private lazy var feedRepository = FeedRepository(
        timelineClient: Timeline_V1_TimelineServiceClient(client: authenticatedRPCClient),
        postClient: Post_V1_PostServiceClient(client: authenticatedRPCClient),
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
        counterClient: Counter_V1_CounterServiceClient(client: authenticatedRPCClient),
        engagementClient: Engagement_V1_EngagementServiceClient(client: authenticatedRPCClient),
        authSession: sessionManager,
        snapshotStore: CodableFileStore<[FeedEntry]>(name: "feed-first-page")
    )

    private lazy var commentsRepository = CommentsRepository(
        commentClient: Comment_V1_CommentServiceClient(client: authenticatedRPCClient),
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
        authSession: sessionManager
    )

    private(set) lazy var feedFeature: any FeedFeatureBuilding = FeedFeatureBuilder(
        repository: feedRepository,
        engagementProvider: feedRepository,
        commentsProvider: commentsRepository,
        realtime: realtimeClient,
        composedPosts: composedPostChannel,
        router: routeResolver,
        imagePipeline: imagePipeline,
        videoPlayback: videoPlayback,
        // The comments composer's avatar opens the same switcher the profile
        // header offers. Lazily, and one instance per composer: the factory
        // caches its pre-formatted rows, so two surfaces sharing one would
        // race over that cache. `unowned self` matches `profileFeature`'s
        // own accessor below — the container outlives every screen.
        makeProfileSwitcher: { [unowned self] in self.profileFeature.makeProfileSwitcher() },
        wallet: walletStore,
        // The SAME sheet the map's badge presents — one claim surface,
        // reachable from wherever the balance is showing.
        makeWalletSheet: { [unowned self] in WalletClaimViewController(wallet: self.walletStore) },
        // A post card's "..." raises moderation cases and unfollows through the
        // SAME two repositories the profile screen uses. Feed sees only the
        // `CoreModels` protocols; which class satisfies them is the composition
        // root's business, which is what lets a feed row report a post without
        // the Feed package knowing the Profile package exists.
        reporting: profileReportRepository,
        socialGraph: profileRepository
    )

    // MARK: - Maps

    /// Reads map pins from geo_discovery.v1 (Radar path). Fleet mode hits the
    /// real service through the gateway; mock mode is served by
    /// `MockGeoDiscoveryService`, which scatters the shared dataset around Paris.
    private lazy var mapsRepository = GeoDiscoveryRepository(
        geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: authenticatedRPCClient),
        // counter.v1, so each tile's pins carry their LIKE counts and a
        // cluster can wear its most popular member's face.
        counterClient: Counter_V1_CounterServiceClient(client: authenticatedRPCClient)
    )

    /// The filter bar's favorites section (Phase 1: the viewer's followed
    /// profiles). Fail-open — on the fleet this resolves empty until a viewer
    /// profile-id resolver reaches the Maps feature (see the repository doc).
    private lazy var mapsFavoritesRepository = MapFavoritesRepository(
        socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient)
    )

    /// A Maps-dedicated player pool for live pin previews, separate from the
    /// feed's, so the two surfaces never contend for players.
    private lazy var mapsVideoPlayback: VideoPlaybackController = {
        let source: any VideoSource = switch environment {
        case .mock: PlaceholderVideoFetcher()
        case .localFleet: PassthroughVideoSource()
        }
        return VideoPlaybackController(source: source)
    }()

    private(set) lazy var mapsFeature: any MapsFeatureBuilding = MapsFeatureBuilder(
        repository: mapsRepository,
        favoritesRepository: mapsFavoritesRepository,
        imagePipeline: imagePipeline,
        videoPlayback: mapsVideoPlayback,
        feedFeature: { [unowned self] in self.feedFeature },
        openProfile: { [unowned self] id, stub in
            self.router.route(to: .profile(id, stub: stub))
        },
        openConversation: { [unowned self] id in
            self.router.route(to: .messageUser(id, stub: nil))
        }
    )

    // MARK: - Profile

    private lazy var profileRepository = ProfileRepository(
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
        counterClient: Counter_V1_CounterServiceClient(client: authenticatedRPCClient),
        socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
        authSession: sessionManager
    )

    /// Files profile reports through `moderation.v1.OpenCase` (the profile's
    /// "..." menu). Mock mode answers it; against the local fleet the service
    /// needs the gateway route added in `dev/envoy/envoy.yaml` — see
    /// `dev/BACKEND_GAPS.md` §11.
    private lazy var profileReportRepository = ProfileReportRepository(
        moderationClient: Moderation_V1_ModerationServiceClient(client: authenticatedRPCClient),
        authSession: sessionManager
    )

    /// The viewer's account details for the settings screen (read-only —
    /// `account.v1` exposes no change-email/phone RPC).
    private lazy var accountRepository = AccountRepository(
        accountClient: Account_V1_AccountServiceClient(client: authenticatedRPCClient),
        authSession: sessionManager
    )

    /// The profile media grid's source: post listing/hydration plus the
    /// search-backed "Tagged" corpus (post caption search — mock indexes it
    /// exactly; fleet quality tracks the search index).
    private lazy var profileGalleryRepository = ProfileGalleryRepository(
        postClient: Post_V1_PostServiceClient(client: authenticatedRPCClient),
        searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient),
        counterClient: Counter_V1_CounterServiceClient(client: authenticatedRPCClient),
        // Resolves whose posts the tiles are. The grid draws none of it; the
        // full-screen page a tile opens into is seeded from the tile's model,
        // and without this that page arrives with an anonymous author capsule
        // until its own fetch answers.
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient)
    )

    /// The share sheet's quick-send row: mutuals first, then the rest of the
    /// follow list. Reuses `profileRepository` as the viewer resolver so the
    /// identity (and a profile switch) is resolved in exactly one place.
    private lazy var profileShareTargetsRepository = ProfileShareTargetsRepository(
        socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
        searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient),
        viewer: profileRepository
    )

    /// The follower / following lists behind the profile header's counters.
    /// Reuses `profileRepository` as the viewer resolver, so identity (and a
    /// profile switch) is resolved in exactly one place.
    ///
    /// `supportsFollowerRemoval` tracks the deployment, not a preference:
    /// `social_graph.v1` has no `RemoveFollower` RPC, so only the mock — which
    /// owns its own graph — can honor the action. Against the fleet the row
    /// simply doesn't offer it. See `dev/BACKEND_GAPS.md` §13.
    private lazy var profileRelationshipsRepository = ProfileRelationshipsRepository(
        socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
        viewer: profileRepository,
        supportsFollowerRemoval: environment == .mock
    )

    private(set) lazy var profileFeature: any ProfileFeatureBuilding = {
        var builder = ProfileFeatureBuilder(
            repository: profileRepository,
            reporting: profileReportRepository,
            shareTargeting: profileShareTargetsRepository,
            gallery: profileGalleryRepository,
            relationships: profileRelationshipsRepository,
            imagePipeline: imagePipeline,
            router: routeResolver,
            account: accountRepository,
            switching: profileRepository
        )
        // The one place that can see both features, which is the whole reason
        // this is injected rather than reached for: Profile describes where a
        // tapped post is, Feed owns the card and the flight, and neither
        // imports the other.
        // The same pool every other surface draws on, so a profile's video
        // competes for the same slots rather than opening a second one.
        builder.videoPlayback = videoPlayback
        builder.openFeedHero = { [weak self] postIDs, presenter, origin in
            self?.feedFeature.presentSnapFeedHero(
                postIDs: postIDs, from: presenter, origin: origin
            )
        }
        // Pinning a profile onto the map's people rail, from the profile
        // screen. The SAME service the map itself writes through, so the rail
        // and the button cannot hold different opinions about who is pinned.
        builder.mapPinning = mapsFeature.profilePinning
        return builder
    }()

    // MARK: - Search

    private lazy var searchRepository = SearchRepository(
        searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient)
    )

    /// The viewer's search history. Device-local — no contract carries one.
    private lazy var recentSearchStore = RecentSearchStore()

    /// The search screen's trending section, served off the SAME feed
    /// repository the timeline and For You read — so one hydration path, one
    /// cache, and a post opened from a trending tile is already warm in the
    /// snap feed it opens into. See `ForYouExploreAdapter`.
    private lazy var exploreRepository = ForYouExploreAdapter(
        forYou: ForYouRepository(feed: feedRepository)
    )

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
    private var cachedProfileMetadataRepository: ProfileMetadataRepository?
    private var profileMetadataRepository: ProfileMetadataRepository {
        if let cachedProfileMetadataRepository { return cachedProfileMetadataRepository }
        let profiles = profileRepository
        let repository = ProfileMetadataRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
            // The relation is asked from the VIEWER's side, so it needs whose
            // side that is; nil before sign-in simply means no context on the
            // rows rather than a wrong one.
            viewerID: { await profiles.viewerProfileID() }
        )
        cachedProfileMetadataRepository = repository
        return repository
    }

    private(set) lazy var searchFeature: any SearchFeatureBuilding = SearchFeatureBuilder(
        repository: searchRepository,
        recentSearches: recentSearchStore,
        explore: exploreRepository,
        metadata: profileMetadataRepository,
        imagePipeline: imagePipeline,
        router: routeResolver
    )

    // MARK: - Notifications

    private lazy var notificationsRepository = NotificationsRepository(
        notificationClient: Notification_V1_NotificationServiceClient(client: authenticatedRPCClient),
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
        authSession: sessionManager
    )

    private(set) lazy var notificationsFeature: any NotificationsFeatureBuilding = NotificationsFeatureBuilder(
        repository: notificationsRepository,
        router: routeResolver
    )

    // MARK: - Chat

    private lazy var chatRepository = ChatRepository(
        chatClient: Chat_V1_ChatServiceClient(client: authenticatedRPCClient),
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
        authSession: sessionManager
    )

    /// Answers both social questions the inbox asks — "do I follow this peer"
    /// (the Requests partition) and "who should I follow next" (Suggestions) —
    /// off the viewer identity `chatRepository` has already resolved and
    /// cached, so neither surface pays for a second lookup.
    private lazy var socialConnectionsRepository = SocialConnectionsRepository(
        socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
        viewer: chatRepository,
        pageSize: 200
    )

    /// The compose picker's people lookup. Its own repository rather than the
    /// Search feature's: features never import each other, so Chat states the
    /// shape it needs (`PeopleDirectoryProviding`) and this is where it gets
    /// pointed at `search.v1` — the same client the Search tab uses.
    private lazy var peopleDirectoryRepository = PeopleDirectoryRepository(
        searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient)
    )

    private(set) lazy var chatFeature: any ChatFeatureBuilding = ChatFeatureBuilder(
        repository: chatRepository,
        connections: socialConnectionsRepository,
        people: peopleDirectoryRepository,
        imagePipeline: imagePipeline,
        router: routeResolver,
        // One history for the whole app: a query typed in the inbox is recent on
        // the search screen, and the other way round.
        recentSearches: recentSearchStore
    )

    // MARK: - Routing

    /// The one place `AppRoute`s become navigation. Features receive it as an
    /// opaque `Router`; the shell binds its `navigator` when it starts.
    private(set) lazy var routeResolver = RouteResolver(
        uploadFeature: uploadFeature,
        profileFeature: { [unowned self] in self.profileFeature },
        feedFeature: { [unowned self] in self.feedFeature },
        chatFeature: { [unowned self] in self.chatFeature }
    )

    var router: any Router { routeResolver }

    // MARK: - Compose / upload

    // Computed (not lazy): the PostComposer init is actor-isolated, which a
    // stored-property initializer can't call under default-MainActor isolation.
    private var cachedPostComposer: PostComposer?
    private(set) var postComposer: PostComposer {
        get {
            if let cachedPostComposer {
                return cachedPostComposer
            }
            let uploadTransport: any MediaUploadTransport = switch environment {
            case .mock:
                MockMediaUploadTransport(store: mockBackend.blobStore)
            case .localFleet:
                // The media service presigns object-store URLs against the
                // Docker-internal host (minio:9000), unreachable from the
                // client; rewrite to the published host, preserving the signed
                // Host header. Remove once the fleet presigns a reachable host.
                URLSessionMediaUploadTransport(
                    hostRewrite: HostRewrite(from: "minio:9000", to: "localhost:9000")
                )
            }
            let composer = PostComposer(
                mediaClient: Media_V1_MediaServiceClient(client: authenticatedRPCClient),
                postClient: Post_V1_PostServiceClient(client: authenticatedRPCClient),
                profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
                authSession: sessionManager,
                uploadTransport: uploadTransport,
                imagePipeline: imagePipeline,
                composedChannel: composedPostChannel
            )
            cachedPostComposer = composer
            return composer
        }
        set { cachedPostComposer = newValue }
    }

    private(set) lazy var uploadFeature: any UploadFeatureBuilding = UploadFeatureBuilder(composer: postComposer)

    /// Stable per-install identifier for session/device management
    /// (auth.v1.DeviceContext.device_id). Not an advertising identifier.
    private static func persistentDeviceID() -> String {
        let key = "device.identifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
