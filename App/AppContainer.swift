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
        case .mock: mockBFF
        case .localFleet: URLSessionHTTPClient()
        }
    }()

    private let mockDataset = MockSocialDataset()
    private lazy var mockCounterStore = MockCounterStore(dataset: mockDataset)
    private let mockBlobStore = MockBlobStore()
    private let mockPostStore = MockPostStore()
    private(set) lazy var mockRealtimeServer = MockRealtimeServer()

    private lazy var mockBFF: MockBFF = {
        let bff = MockBFF()
        MockAuthService().register(on: bff)
        MockSocialServices(dataset: mockDataset, postStore: mockPostStore).register(on: bff)
        MockEngagementService(store: mockCounterStore).register(on: bff)
        MockCounterService(store: mockCounterStore).register(on: bff)
        MockMediaService(store: mockBlobStore).register(on: bff)
        MockPostAuthoringService(store: mockPostStore).register(on: bff)
        MockSearchService(dataset: mockDataset).register(on: bff)
        MockNotificationService(dataset: mockDataset).register(on: bff)
        MockCommentService(dataset: mockDataset).register(on: bff)
        MockChatService(dataset: mockDataset).register(on: bff)
        MockSocialGraphService(dataset: mockDataset).register(on: bff)
        return bff
    }()

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
            PlaceholderImageFetcher()
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
        let posts = mockDataset.posts.prefix(6).map(\.postID)
        let store = mockCounterStore
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

    /// The timeline presentation. `-snap-feed` swaps the classic list for the
    /// full-screen, page-snapping media feed (Phase 1). Read once here so the
    /// Feed package stays free of launch-argument parsing, and shared with the
    /// tab coordinator, which adapts its chrome to match.
    let feedPresentation: FeedPresentationStyle =
        ProcessInfo.processInfo.arguments.contains("-snap-feed") ? .snap : .classic

    private(set) lazy var feedFeature: any FeedFeatureBuilding = FeedFeatureBuilder(
        repository: feedRepository,
        engagementProvider: feedRepository,
        commentsProvider: commentsRepository,
        realtime: realtimeClient,
        composedPosts: composedPostChannel,
        router: routeResolver,
        imagePipeline: imagePipeline,
        videoPlayback: videoPlayback,
        presentation: feedPresentation
    )

    // MARK: - Profile

    private lazy var profileRepository = ProfileRepository(
        profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
        counterClient: Counter_V1_CounterServiceClient(client: authenticatedRPCClient),
        socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
        authSession: sessionManager
    )

    private(set) lazy var profileFeature: any ProfileFeatureBuilding = ProfileFeatureBuilder(
        repository: profileRepository,
        imagePipeline: imagePipeline,
        router: routeResolver
    )

    // MARK: - Search

    private lazy var searchRepository = SearchRepository(
        searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient)
    )

    private(set) lazy var searchFeature: any SearchFeatureBuilding = SearchFeatureBuilder(
        repository: searchRepository,
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

    private(set) lazy var chatFeature: any ChatFeatureBuilding = ChatFeatureBuilder(
        repository: chatRepository,
        router: routeResolver
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
                MockMediaUploadTransport(store: mockBlobStore)
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
