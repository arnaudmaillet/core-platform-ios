import LaunchArguments
import UIKit
import Auth
import AuthInterface
import CacheKit
import Chat
import ChatInterface
import Connect
import CoreLocation
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
import DesignSystem
import EntityStore
import Feed
import FeedInterface
import Foundation
import LocalStore
import Maps
import MapsInterface
import Notifications
import NotificationsInterface
import PlaceInterface
import Profile
import ProfileData
import ProfileInterface
import Search
import SearchInterface
import Settings
import SettingsInterface
import Upload
import Wallet
#if DEBUG
import DebugTools
#endif

/// Composition root. The only place concrete implementations are chosen and
/// wired; everything downstream receives protocols via initializer injection.
///
/// ONE CLASS, A FILE PER DOMAIN (#2375). This file holds the container's
/// infrastructure — the environment, the transports and RPC clients, the mock
/// backend, the session and the viewer, realtime — and DECLARES every stored
/// property, since an extension can hold none. Each domain's file
/// (`AppContainer+Feed.swift`, `+Maps`, `+Chat`…) builds its properties — a
/// lazy property whose initializer is longer than a line is a `make…()` there —
/// and holds the domain's behaviour.
final class AppContainer {

    static let shared = AppContainer()

    private init() {}

    /// Selected by launch argument: `.mock` (default) or `.localFleet`.
    let environment = AppEnvironment.current

    /// The transport for Connect RPCs: the in-process mock, or the real
    /// URLSession client pointed at the Envoy gateway.
    private lazy var rpcHTTPClient: any HTTPClientInterface = {
        let transport: any HTTPClientInterface
        switch environment {
        case .mock: transport = mockBackend.bff
        case .localFleet: transport = URLSessionHTTPClient()
        }
        #if DEBUG
        // The debug dashboard's network log (#2133): one flag read per call
        // while it is off.
        return NetworkLogClient(wrapping: transport)
        #else
        return transport
        #endif
    }()

    /// The whole in-process backend (dataset + stores + fully registered
    /// MockBFF), with network realism read from launch arguments
    /// (`-mock-latency`, `-mock-fail`, `-mock-fail-code`, `-mock-fail-rate`).
    private(set) lazy var mockBackend: MockBackend = {
        let backend = MockBackend(
            conditions: .fromLaunchArguments(),
            mediaCatalog: Self.usesRichMedia ? .realAssets : .synthetic,
            seedsMapHierarchy: Self.seedsMapPlaces,
            // A guest's write is refused here as at the fleet's edge, so a missing
            // gate shows up in mock mode (`[edge] REFUSED` in the console).
            // `-mock-open-edge` turns it off for QA that predates guest mode.
            enforcesEdgePolicy: !LaunchArgument.mockOpenEdge.isPassed(),
            // A place page asked by country code (#643): the map's borders.
            countryOf: { latitude, longitude in
                CountryAtlas.shared.country(owning: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))?.code
            },
            // Groups and channels (#2213): the mock seeds them only under
            // their flags.
            seedsGroups: DebugFlags.isOn("-group-chats"),
            seedsChannels: DebugFlags.isOn("-channels"),
            // Voice posts drawn (#2206): the mock then serves voice-alone
            // posts without their text.
            drawsVoicePosts: DebugFlags.isOn("-voice-posts"),
            groupGoesPrivateAfter: Self.groupGoesPrivateAfter
        )
        backend.bff.faults = mockNetworkFaults
        #if DEBUG
        Self.seedViewHistoryIfAsked(from: backend.dataset)
        #endif
        return backend
    }()

    #if DEBUG
    /// `-mock-view-history`: the profile's History (#2170) filled with a
    /// varied pile of the mock's posts — clips, photos, carousels, text
    /// posts, one without a caption, the longest caption and author name —
    /// viewed from minutes to months ago, so its rows and day groups can be
    /// looked at without viewing each post first. Replaces the pile on every
    /// launch that asks.
    private static func seedViewHistoryIfAsked(from dataset: MockSocialDataset) {
        guard LaunchArgument.mockViewHistory.isPassed() else { return }
        let posts = dataset.posts.filter { $0.parentID.isEmpty }
        let isVideo: (MockSocialDataset.PostRecord) -> Bool = {
            $0.media.map { MockMediaFixtures.isVideoURL($0.url) } ?? false
        }
        let nameLength: (MockSocialDataset.PostRecord) -> Int = {
            dataset.author(for: $0.authorProfileID)?.displayName.count ?? 0
        }
        var picked: [String] = []
        func take(_ candidates: [MockSocialDataset.PostRecord], _ count: Int) {
            var added = 0
            for post in candidates where added < count && !picked.contains(post.postID) {
                picked.append(post.postID)
                added += 1
            }
        }
        take(posts.filter { $0.media != nil && $0.caption.count > 70 }.sorted { $0.caption.count > $1.caption.count }, 1)
        take(posts.filter(isVideo), 3)
        take(posts.filter { !$0.extraMedia.isEmpty }, 2)
        take(posts.filter { $0.media == nil }, 3)
        take(posts.filter { $0.media != nil && !isVideo($0) && $0.extraMedia.isEmpty }, 4)
        take(posts.filter { $0.media != nil && $0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, 1)
        take(posts.sorted { nameLength($0) > nameLength($1) }, 1)
        take(posts.filter { ($0.seededLikes ?? 0) > 1_000 }, 1)
        take(posts, 22 - picked.count)
        // Minutes to months: Today, Yesterday, this week and the last,
        // this month and the last, then months by name.
        let hours: [Double] = [0.1, 0.5, 2, 5, 9, 26, 30, 50, 75, 100]
        let days: [Double] = [8, 9, 12, 20, 26, 40, 45, 70, 75, 100, 130, 160]
        let ages: [TimeInterval] = hours.map { $0 * 3600 } + days.map { $0 * 86_400 }
        PostViewHistoryStore.shared.debugPendingSeed = zip(picked, ages).map { (id: $0, age: $1) }
    }
    #endif

    /// Offline, timed outages, lost acks and upload faults for the WHOLE mock
    /// network — BFF, upload transport and realtime together (#790):
    /// `-mock-offline`, `-mock-outage 20+30`, `-mock-ack-loss <path|all>`,
    /// `-mock-upload-fail 0.5`, and at runtime the shake sheet
    /// (`NetworkConditionsMenu`).
    private(set) lazy var mockNetworkFaults = MockNetworkFaults.fromLaunchArguments()
    private var mockFaultsObserver: NSObjectProtocol?
    private var connectivityBridge: NSObjectProtocol?

    /// Starts telling the app whether the network is reachable (#793): the
    /// system path on the fleet, the mock network's switchboard in mock mode
    /// (a simulator's path cannot be faked).
    @MainActor
    func startConnectivityMonitoring() {
        switch environment {
        case .mock:
            let faults = mockNetworkFaults
            ConnectivityMonitor.shared.report(online: !faults.isOffline)
            connectivityBridge = NotificationCenter.default.addObserver(
                forName: MockNetworkFaults.didChange, object: faults, queue: .main
            ) { _ in
                MainActor.assumeIsolated { ConnectivityMonitor.shared.report(online: !faults.isOffline) }
            }
        case .localFleet:
            ConnectivityMonitor.shared.startMonitoringSystemPath()
        }
    }

    /// Semantic map clusters (city/country places on the mock pins, and the
    /// European seed behind them) are the DEFAULT mock experience — no
    /// launch argument required. `-maps-mock-no-places` opts out, for the
    /// proximity/Case-A QA where strict banding would otherwise hide
    /// untagged pins. One decision, handed to both the geo mock's seeding
    /// and the Maps feature's place decoration so the two can never
    /// disagree.
    static let seedsMapPlaces =
        !LaunchArgument.mapsMockNoPlaces.isPassed()

    /// `-rich-media`: seed the mock dataset's AVATARS from `MockMediaFixtures`
    /// — real photographs at exact dimensions — instead of the synthesized
    /// `mock://` pictures. Post media is the corpus's own bundled clips and
    /// photo galleries either way (`MockClipCatalog`, `MockPhotoCatalog`).
    ///
    /// Opt-in on purpose. The default mock mode is offline and deterministic,
    /// which is what the unit suite and CI depend on; this flag trades that for
    /// realism (real image decode cost) when driving the app by hand. It
    /// requires network.
    static let usesRichMedia = LaunchArgument.richMedia.isPassed()

    private(set) lazy var mockRealtimeServer: MockRealtimeServer = {
        let server = MockRealtimeServer()
        // Offline refuses the socket too, and the outage's end lets it back.
        let faults = mockNetworkFaults
        server.refusesConnections = faults.isOffline
        mockFaultsObserver = NotificationCenter.default.addObserver(
            forName: MockNetworkFaults.didChange, object: faults, queue: .main
        ) { _ in
            if server.refusesConnections != faults.isOffline { server.refusesConnections = faults.isOffline }
        }
        return server
    }()

    /// Bridge from the compose feature to the feed's optimistic insert.
    let composedPostChannel = ComposedPostChannel()
    /// The viewer's accepted follows and unfollows, announced by every
    /// repository that writes them and heard by every surface that shows one
    /// — see `FollowGraphEvents`. One instance, like the channel above. A
    /// change made as a profile that is no longer the active one is dropped
    /// (#978): the active profile is the one `StorageScope` holds.
    let followGraphEvents = FollowGraphEvents(currentViewer: {
        guard case .member(_, let profile?) = StorageScope.shared.owner else { return nil }
        return ProfileID(profile)
    })

    private lazy var unauthenticatedRPCClient = ConnectClientFactory.makeUnauthenticated(
        host: environment.host,
        wire: environment.wire,
        httpClient: rpcHTTPClient
    )

    /// RPC client for everything except AuthService; attaches the edge token
    /// and refreshes it single-flight.
    private(set) lazy var authenticatedRPCClient: ProtocolClientInterface = ConnectClientFactory.makeAuthenticated(
        host: environment.host,
        tokenProvider: sessionManager,
        wire: environment.wire,
        httpClient: rpcHTTPClient
    )

    private(set) lazy var sessionManager: SessionManager = SessionManager(
        authClient: Auth_V1_AuthServiceClient(client: unauthenticatedRPCClient),
        store: KeychainSessionStore(store: KeychainStore(service: "cn.wynn.core-platform-ios")),
        configuration: .init(deviceID: Self.persistentDeviceID(), userAgent: Self.userAgent()),
        // A guest reads with a token of their own (guest mode B1), started on
        // the first read, with an App Attest proof where the device has one
        // (#523) and the country location says it's in (B10).
        guest: GuestSessionContext(
            store: KeychainSessionStore(
                store: KeychainStore(service: "cn.wynn.core-platform-ios"), key: "auth.guestSession"
            ),
            currentCountry: { [weak self] in await self?.currentCountry.currentCountry },
            attestor: AppAttestGuestAttestor(keyStore: KeychainStore(service: "cn.wynn.core-platform-ios"))
        )
    )

    /// Who is signed in and as which profile, for the whole app: every
    /// repository that needs the viewer asks this one session, so a profile
    /// switch or a sign-out reaches all of them at once.
    private(set) lazy var viewerSession = ViewerSession(authSession: sessionManager) { [authenticatedRPCClient] account in
        try await AccountProfilesReader.profileIDs(
            ofAccount: account.rawValue,
            using: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient)
        )
        .map { ProfileID($0) }
    }

    private var viewerTransitionsTask: Task<Void, Never>?
    private var storageScopeTask: Task<Void, Never>?

    /// The question every write asks before it runs: is there an account? A
    /// guest is shown the sign-up sheet and the write carries on once they are
    /// signed in (`MemberGating`). The app coordinator presents the sheet and
    /// keeps `isMember` in step with the session.
    let memberGate = MemberGate()

    /// Drops every viewer-scoped cache when the viewer becomes someone else —
    /// another account, a sign-out or a profile switch. Started by the app
    /// coordinator once its startup sign-in sequence is over, so that sequence
    /// never counts as a change.
    func observeViewerTransitions() {
        guard viewerTransitionsTask == nil else { return }
        let viewer = viewerSession
        // Every app-lifetime cache holding answers computed FOR the viewer
        // (#892): their follow state, their requests, their filtered pages.
        // The device store is wiped by the cache coordinator, on the
        // `.viewerDidChange` posted below (#893).
        let scoped: [any ViewerScoped] = [
            commentsRepository, profileRelationshipsRepository, profileMetadataRepository,
            // What notification lookups answered, missing posts included (#978).
            notificationsRepository,
            // A teen's time not yet reported is that account's (#417).
            supervisedScreenTime,
            // The posts and authors read for the viewer (#2047): a member's
            // private authors were served to the guest after a sign-out.
            feedRepository
        ]
        viewerTransitionsTask = Task {
            for await state in await viewer.transitions() {
                for cache in scoped {
                    await cache.viewerDidChange(state)
                }
                NotificationCenter.default.post(name: .viewerDidChange, object: nil)
            }
        }
    }

    /// Points the identity-bearing stores at whoever `state` says is here
    /// (`StorageScope`). Synchronous on purpose: the app coordinator calls it
    /// before anything writes for the new viewer. The ACCOUNT is known now;
    /// its active profile arrives from the viewer session
    /// (`observeStorageScope`), and the profile's keys use the account's
    /// until then.
    func enterStorageScope(for state: AuthState) {
        let scope = StorageScope.shared
        switch state {
        case .unauthenticated:
            scope.owner = .guest
            TeenProtections.shared.clear()
        case .authenticated(let account):
            // The same account keeps the profile it already resolved.
            if case .member(account.rawValue, _) = scope.owner { return }
            scope.owner = .member(account: account.rawValue, profile: nil)
            // Teen protections (#401): reading the account records its age
            // bracket on this device (`AccountRepository.currentAccount`).
            Task { [weak self] in _ = try? await self?.accountRepository.currentAccount() }
        }
        observeStorageScope()
        restoreEntitiesFromDevice()
    }

    /// Rebuilds the app's posts from the device store (#896) once per
    /// launch, as soon as the store knows who is here — the same moment the
    /// tabs open on their stored lists, which then share these entities.
    private func restoreEntitiesFromDevice() {
        guard !didRestoreEntities else { return }
        didRestoreEntities = true
        _ = entityStore
        guard let backing = entityDeviceBacking else { return }
        Task.detached(priority: .userInitiated) { backing.restore() }
    }

    private var didRestoreEntities = false

    /// The active profile, as the viewer session resolves it or a switch
    /// changes it — the profile half of `StorageScope`.
    private func observeStorageScope() {
        guard storageScopeTask == nil else { return }
        let viewer = viewerSession
        storageScopeTask = Task { @MainActor in
            for await state in await viewer.updates() {
                guard case .member(let account, let profile?) = state,
                      case .member(account.rawValue, _) = StorageScope.shared.owner else { continue }
                StorageScope.shared.owner = .member(account: account.rawValue, profile: profile.rawValue)
            }
        }
    }

    /// The profile a handle or a share token names — what a profile pushed
    /// from a `@handle` or a link asks once it is on screen (#800).
    func profileID(for reference: ProfileReference) async -> ProfileLookup {
        switch reference {
        case .handle(let handle): await profileID(forHandle: handle)
        case .shareToken(let token): await profileID(forShareToken: token)
        }
    }

    /// The profile a `@handle` names (`profile.v1.GetProfileByHandle`, #524).
    private func profileID(forHandle handle: String) async -> ProfileLookup {
        var request = Profile_V1_GetProfileByHandleRequest()
        request.handle = handle
        let response = await Profile_V1_ProfileServiceClient(client: authenticatedRPCClient)
            .getProfileByHandle(request: request, headers: [:])
        if let view = response.message { return .found(ProfileID(view.profileID)) }
        return response.error?.code == .notFound ? .missing : .unavailable
    }

    /// The profile a QR code or `core-platform.click/s/<token>` link opens
    /// (`profile.v1.ResolveShareToken`, #412). `.missing` covers a reset
    /// token and an owner who switched links off: the server tells them apart
    /// from no one.
    private func profileID(forShareToken token: String) async -> ProfileLookup {
        var request = Profile_V1_ResolveShareTokenRequest()
        request.token = token
        let response = await Profile_V1_ProfileServiceClient(client: authenticatedRPCClient)
            .resolveShareToken(request: request, headers: [:])
        if let view = response.message { return .found(ProfileID(view.profileID)) }
        return response.error?.code == .notFound ? .missing : .unavailable
    }

    private(set) lazy var authFeature: any AuthFeatureBuilding = makeAuthFeature()

    // MARK: - Device cache

    /// The one owner of every cache budget in the process (epic #890). Every
    /// memory and disk namespace registers here (`register(_:)`): images
    /// (#894), video (#895), the LocalStore (#893), UI assets (#971). It turns
    /// each namespace's budget rule into bytes from the device and the
    /// Settings limit, and releases memory and disk on the signals
    /// `startCacheCoordinator()` wires.
    ///
    /// Starts on the device's Settings → Storage choices (#899): the storage
    /// limit (`.automatic` = images 300 MB, video 500 MB, LocalStore 100 MB,
    /// unless the viewer chose 0.5, 1 or 2 GB) and Use Less Cellular Data.
    /// Settings applies later changes to it directly.
    let cacheCoordinator = CacheCoordinator(
        storageLimit: CacheStoragePreference.load(),
        conditions: CacheConditions(usesLessCellularData: MediaPlaybackPreferencesStore.standard.preferences.dataSaver)
    )

    var cacheSignalsStarted = false
    var releaseObservation: CacheObservation?
    #if DEBUG
    var cacheAudit: CacheAudit?
    #endif

    /// One post and one profile per id, read by every screen (#896): a like,
    /// a follow, a save or a delete made on one reaches all of them. Its
    /// content namespaces and the viewer's facts register with
    /// `cacheCoordinator`, which bounds them and wipes the viewer's facts on
    /// every viewer change. A follow the graph accepts, from any repository,
    /// is written in (`FollowGraphEvents`).
    private(set) lazy var entityStore: EntityStore = makeEntityStore()

    /// Keeps `entityStore` hearing the follow channel for the app's life.
    var entityFollowSubscription: FollowGraphSubscription?
    /// Keeps `entityStore`'s counts moving with the wallet's stakes.
    var walletStakeLikes: WalletStakeLikes?
    /// `entityStore`'s device half: nil without a device store.
    var entityDeviceBacking: EntityDeviceBacking?

    // MARK: - Device store

    /// The device's copies of server data (#893): each tab's last pages, so
    /// a cold start opens on them and then revalidates. Viewer-scoped by
    /// `StorageScope`. A namespace of `cacheCoordinator`, which sets its
    /// budget (the `.localStore` pool, 100 MB in Automatic), sweeps it in the
    /// background and wipes it on every viewer change. Nil only when the file
    /// cannot be opened even after a reset: the app then runs without it, as
    /// it did before.
    private(set) lazy var localStore: LocalStore? = makeLocalStore()

    // MARK: - Viewer storage (#2376)

    /// Which sections each screen showed last time (#1774): the skeleton's
    /// memory, ONE store for every screen that draws one — the thread, the
    /// place page, the profile's gallery, Search.
    private(set) lazy var sectionPresence = SectionPresenceStore()

    /// The received voice messages the viewer played (#2104): every
    /// conversation reads the same memory.
    private(set) lazy var voicePlayed = VoicePlayedStore()

    // MARK: - Media

    /// Mock mode serves the corpus's bundled photos for `mock://photo/…` URLs
    /// and deterministic placeholder images for any other `mock://` URL;
    /// fleet mode fetches real images over HTTP, rewriting the fleet's
    /// Docker-internal minio host to the published one.
    private(set) lazy var imagePipeline: ImagePipeline = makeImagePipeline()

    private(set) lazy var videoPlayback: VideoPlaybackController = {
        Self.sizedToPreference(VideoPlaybackController(source: makeVideoSource(), byteCache: videoByteCache))
    }()

    /// The device cache's video bytes (#895): progressive files read through
    /// it from disk, gaps fetched and written back, and the vertical feed's
    /// head preloads. Its two namespaces (public and signed) join
    /// `cacheCoordinator` in the `.video` pool (500 MB in Automatic); the
    /// signed one is wiped on every viewer change. Shared by both playback
    /// pools: one store per namespace per process. Its stores open on the
    /// cache's own queue, never here on main (#1018); if they cannot open,
    /// players stream as they did before.
    private lazy var videoByteCache: VideoByteCache = VideoByteCache(coordinator: cacheCoordinator)

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

    /// The viewer's wallet behind the currency badge, the claim sheet and
    /// every boost button: a member's is `wallet.v1`'s
    /// (`BACKEND_VIRTUAL_CURRENCY.md`, what the app binds to); a guest's
    /// stays on the device.
    /// ONE instance, deliberately: `WalletStore`'s change notification is
    /// scoped to the instance that changed, so the map badge only hears
    /// about a feed spend because both surfaces hold this same object.
    private(set) lazy var walletStore: WalletStore = makeWalletStore()

    /// Reads the member's wallet from the server at the moments it can have
    /// moved (#1098); started once, from the scene.
    var walletServerSync: WalletServerSync?

    /// The likes a guest's sign-up brings: a flat 50, once per device, never
    /// named to the guest (#1146, the owner 2026-10-14). The app coordinator
    /// opens it for a guest and settles it into `walletStore` for a member.
    private(set) lazy var welcomeGift = WelcomeGift()

    // MARK: - Likes (#676)

    /// The likes waiting to be committed, persisted across launches.
    private(set) lazy var likeOutbox = LikeOutbox()
    /// `wallet.Stake`, as the signed-in account.
    private(set) lazy var likeStaking: WalletLikeStaking = makeLikeStaking()
    /// Commits `likeOutbox`; started with `walletStore`.
    var likeOutboxSender: LikeOutboxSender?
    /// The wallet history's first pages in `localStore` (#1776).
    private(set) lazy var walletHistoryCache: WalletHistoryLocalCache? = localStore.map(WalletHistoryLocalCache.init(store:))

    /// The gem-shop items a profile wears (#944): the account's, bought with
    /// the wallet's gems. Mock mode only, like `countryAccess`: the fleet
    /// carries no ownership yet (core-platform-backend#915).
    private(set) lazy var profileItems: ProfileItemService? = makeProfileItems()

    /// The Shop's Boosts: the ×100 cartridge pack, over the ONE wallet. Mock
    /// mode only, like the shop itself (no `countryAccess`, no shop door).
    private(set) lazy var stakePacks: StakePackService? = makeStakePacks()

    // MARK: - Saves (#837)

    /// Sends every save to engagement (queued offline, replayed) and reads
    /// the Saved tab's list from it, through `PostBookmarkStore.shared`.
    var savedPostsSync: SavedPostsSync?

    // MARK: - Feed

    /// A page of posts' likes and comments, one batched `counter.v1` read
    /// (#2377): the feed's cards, Discover, the place page and the profile
    /// gallery read their counters through it.
    private(set) lazy var postCounters = PostCounterReader(client: Counter_V1_CounterServiceClient(client: authenticatedRPCClient))

    /// The Text Post page's drafts: ONE store for the app's lifetime.
    ///
    /// ⚠️ Built once here and handed to the feed builder, because
    /// `PostDraftStore()` reads and decodes its file in its init, and the
    /// builder used to construct a fresh one every time "+" → Text Post
    /// presented the composer — a synchronous disk read in the turn that
    /// presents a sheet (charter P4). The drafts list inside the composer
    /// shares the same instance, so the two can never disagree.
    private(set) lazy var postDraftStore = PostDraftStore()

    private(set) lazy var feedRepository: FeedRepository = makeFeedRepository()

    /// The feed's lists in `localStore`: For You's two corpora and the
    /// Following feed.
    private(set) lazy var feedLocalCache: FeedLocalCache? = localStore.map(FeedLocalCache.init(store:))

    /// Forwards every profile switch to `commentsRepository`, for as long as the
    /// container lives.
    var activeViewerObserver: NSObjectProtocol?

    private(set) lazy var commentsRepository = makeCommentsRepository()

    private(set) lazy var feedFeature: any FeedFeatureBuilding = feedBuilder

    /// The feed's builder itself: the place page (#2381) takes its hydration,
    /// its relation marks and its comment warm-up, which the interface does
    /// not carry.
    private(set) lazy var feedBuilder: FeedFeatureBuilder = makeFeedBuilder()

    /// Discover's pool (`timeline.v1.GetDiscoveryFeed`, backend B3 / #512):
    /// the same for guests and members, hydrated through the one feed
    /// repository. Also the search screen's trending corpus.
    private(set) lazy var discoveryRepository: DiscoveryFeedRepository = makeDiscoveryRepository()

    /// Set by the shell, which owns the presentation of the camera.
    var onUseSound: (@MainActor (PostSound) -> Void)?

    // MARK: - Place

    /// The place page (#2381): opened by the map (under a cluster's feed) and
    /// by a place link. It opens posts in the feed's reader and draws the
    /// feed's hydration, so every post the feed above holds is a cache hit.
    private(set) lazy var placeFeature: any PlaceFeatureBuilding = makePlaceFeature()

    // MARK: - Maps

    /// Reads map pins from geo_discovery.v1 (Radar path). Fleet mode hits the
    /// real service through the gateway; mock mode is served by
    /// `MockGeoDiscoveryService`, which scatters the shared dataset around Paris.
    private(set) lazy var mapsRepository: GeoDiscoveryRepository = makeMapsRepository()

    /// The filter bar's favorites section (Phase 1: the viewer's followed
    /// profiles). Fail-open — on the fleet this resolves empty until a viewer
    /// profile-id resolver reaches the Maps feature (see the repository doc).
    private(set) lazy var mapsFavoritesRepository: MapFavoritesRepository = makeMapsFavoritesRepository()

    /// A Maps-dedicated player pool for live pin previews, separate from the
    /// feed's, so the two surfaces never contend for players.
    private(set) lazy var mapsVideoPlayback: VideoPlaybackController = {
        Self.sizedToPreference(VideoPlaybackController(source: makeVideoSource(), byteCache: videoByteCache))
    }()

    /// The account's unlocked countries — the map shows only their posts.
    /// Mock mode only: the fleet carries no unlocks yet
    /// (`dev/issues/BACKEND_COUNTRY_UNLOCKS.md`), and a map that hid every
    /// post until then would be broken, not locked.
    private(set) lazy var countryAccess: CountryAccessService? = makeCountryAccess()

    /// Where the device is, as a country — asked for in context from the map
    /// (guest mode §3.1), never at launch. Opens that country for free.
    private(set) lazy var currentCountry: CurrentCountryProvider = makeCurrentCountry()

    private(set) lazy var mapsFeature: any MapsFeatureBuilding = makeMapsFeature()

    // MARK: - Profile

    private(set) lazy var profileRepository: ProfileRepository = makeProfileRepository()

    /// Files reports through `moderation.v1.SubmitReport` (the "..." menus)
    /// and lists them back (Safety → Your Reports, `ListMyReports`). Mock mode
    /// answers both; against the local fleet the service
    /// needs the gateway route added in `dev/envoy/envoy.yaml` — see
    /// `dev/BACKEND_GAPS.md` §11.
    private(set) lazy var profileReportRepository: ProfileReportRepository = makeProfileReportRepository()

    /// The viewer's account details for the settings screen (read-only —
    /// `account.v1` exposes no change-email/phone RPC).
    private(set) lazy var accountRepository: AccountRepository = makeAccountRepository()

    /// A supervised teen's foreground time, queued and reported (#417).
    /// Only an account the device knows to be 13–17 reports anything.
    private(set) lazy var supervisedScreenTime: SupervisedScreenTime = makeSupervisedScreenTime()

    /// The profile media grid's source: post listing/hydration plus the
    /// search-backed "Tagged" corpus (post caption search — mock indexes it
    /// exactly; fleet quality tracks the search index).
    private(set) lazy var profileGalleryRepository: ProfileGalleryRepository = makeProfileGalleryRepository()

    /// The share sheet's quick-send row: mutuals first, then the rest of the
    /// follow list. Reuses `profileRepository` as the viewer resolver so the
    /// identity (and a profile switch) is resolved in exactly one place.
    private(set) lazy var profileShareTargetsRepository: ProfileShareTargetsRepository = makeProfileShareTargetsRepository()

    /// The follower / following lists behind the profile header's counters.
    /// Reuses `profileRepository` as the viewer resolver, so identity (and a
    /// profile switch) is resolved in exactly one place.
    ///
    /// Followers can be removed everywhere: `social_graph.v1.RemoveFollower`
    /// (backend #720), which the mock answers too.
    private(set) lazy var profileRelationshipsRepository: ProfileRelationshipsRepository = makeProfileRelationshipsRepository()

    private(set) lazy var profileFeature: any ProfileFeatureBuilding = makeProfileFeature()

    // MARK: - Settings

    /// "Where you're logged in": `auth.v1` ListSessions / Logout / LogoutAllSessions
    /// on the AUTHENTICATED client — they act on the calling principal's account.
    /// Also the shell's passkey offer after a sign-in (#840), through Settings.
    private(set) lazy var accountSessionsRepository: AccountSessionsRepository = makeAccountSessionsRepository()

    /// Settings → Account Status: `moderation.v1.GetEnforcementState` for the
    /// account, and each restriction's statement of reasons and appeal. Mock mode answers it (`-mock-account-restricted` seeds one
    /// restriction); against the local fleet `moderation.v1` still needs its
    /// gateway route — `dev/BACKEND_GAPS.md` §11.
    /// Settings → Notifications: `notification.v1` push preferences for the
    /// active profile (#392). Nothing sends a push yet: the server's sender
    /// waits on APNs credentials, and this app doesn't register a device.
    private(set) lazy var notificationPreferencesRepository: NotificationPreferencesRepository = makeNotificationPreferencesRepository()

    private(set) lazy var accountStatusRepository: AccountStatusRepository = makeAccountStatusRepository()

    /// Settings and Account (#2382): every screen's dependency typed, so a
    /// missing one fails to compile rather than leaving its row "Coming Soon".
    private(set) lazy var settingsFeature: any SettingsFeatureBuilding = makeSettingsFeature()

    // MARK: - Search

    private(set) lazy var searchRepository: SearchRepository = makeSearchRepository()

    /// `@` and `#` completions for every composer (#524), handed to the shell
    /// so composers find it up their responder chain.
    private(set) lazy var textCompletions: any TextCompletionProviding = makeTextCompletions()

    /// The viewer's search history. Device-local — no contract carries one.
    private(set) lazy var recentSearchStore = RecentSearchStore()

    /// The search screen's trending section, served off the SAME feed
    /// repository the timeline and For You read — so one hydration path, one
    /// cache, and a post opened from a trending tile is already warm in the
    /// snap feed it opens into. See `DiscoverExploreAdapter`.
    private(set) lazy var exploreRepository: DiscoverExploreAdapter = makeExploreRepository()

    /// `profileMetadataRepository`'s instance, once built (`AppContainer+Search.swift`).
    var cachedProfileMetadataRepository: ProfileMetadataRepository?
    /// Keeps `profileMetadataRepository` hearing the follow channel.
    var profileMetadataFollowSubscription: FollowGraphSubscription?

    private(set) lazy var searchFeature: any SearchFeatureBuilding = makeSearchFeature()

    // MARK: - Notifications

    private(set) lazy var notificationsRepository: NotificationsRepository = makeNotificationsRepository()

    /// Push notifications (#651): this install's registration, what a tap
    /// opens, the app icon's badge. See `PushNotifications`.
    private(set) lazy var pushNotifications = makePushNotifications()

    private(set) lazy var notificationsFeature: any NotificationsFeatureBuilding = makeNotificationsFeature()

    // MARK: - Chat

    private(set) lazy var chatRepository: ChatRepository = makeChatRepository()

    /// Answers "who should I follow next" (Suggestions) off the viewer
    /// identity `chatRepository` has already resolved and cached, so the
    /// surface pays for no second lookup.
    private(set) lazy var socialConnectionsRepository: SocialConnectionsRepository = makeSocialConnectionsRepository()

    /// The compose picker's people lookup. Its own repository rather than the
    /// Search feature's: features never import each other, so Chat states the
    /// shape it needs (`PeopleDirectoryProviding`) and this is where it gets
    /// pointed at `search.v1` — the same client the Search tab uses.
    private(set) lazy var peopleDirectoryRepository: PeopleDirectoryRepository = makePeopleDirectoryRepository()

    /// Where the viewer stands with each inbox peer, for the rows' mark and
    /// its "+" (#2049): one read per peer, kept in `entityStore` — the one
    /// copy every surface reads, wiped with the viewer's facts.
    private(set) lazy var inboxRelations: InboxRelations = makeInboxRelations()

    private(set) lazy var chatFeature: any ChatFeatureBuilding = makeChatFeature()

    // MARK: - Routing

    /// The one place `AppRoute`s become navigation. Features receive it as an
    /// opaque `Router`; the shell binds its `navigator` when it starts.
    private(set) lazy var routeResolver: RouteResolver = makeRouteResolver()

    var router: any Router { routeResolver }

    // MARK: - Compose / upload

    /// `postComposer`'s instance, once built (`AppContainer+Upload.swift`).
    var cachedPostComposer: PostComposer?

    // MARK: - Device identity

    /// Stable per-install identifier for session/device management
    /// (auth.v1.DeviceContext.device_id). Not an advertising identifier.
    static func persistentDeviceID() -> String {
        let key = "device.identifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    /// `core-platform-ios/<version> (<model>; iOS <version>)` — the shape
    /// `SessionDevice(userAgent:)` reads back, so "Where you're logged in"
    /// shows "iPhone · iOS 27.0" rather than an opaque string.
    private static func userAgent() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let device = UIDevice.current
        return "core-platform-ios/\(version) (\(device.model); \(device.systemName) \(device.systemVersion))"
    }
}
