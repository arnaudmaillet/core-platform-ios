import Connect
import CoreNetworking
import Foundation

/// One-call assembly of the whole in-process backend: the shared dataset,
/// the mutable stores, and a `MockBFF` with every mock service registered —
/// the same wiring `AppContainer` uses in mock mode, reusable from previews,
/// unit tests, and UI-test hosts that want the full surface rather than a
/// hand-picked subset.
public struct MockBackend: Sendable {
    public let dataset: MockSocialDataset
    /// The map's mock — also asked where each post stands.
    public let geoDiscovery: MockGeoDiscoveryService
    public let counterStore: MockCounterStore
    public let blobStore: MockBlobStore
    public let postStore: MockPostStore
    /// Held (not just registered) so tests can read back the cases the
    /// profile's Report action filed.
    public let moderationService: MockModerationService
    public let bff: MockBFF

    /// `mediaCatalog` defaults to `.synthetic` so tests and previews stay
    /// offline; `AppContainer` passes `.realAssets` under `-rich-media`.
    /// `seedsMapHierarchy` spreads a third of the corpus across the European
    /// geo anchors (`MockGeoDiscoveryService`) and appends the posts
    /// published beyond France (`MockWorldSeed`) — the app passes true in mock
    /// mode (semantic map clusters are the default experience, opt out with
    /// `-maps-mock-no-places`); the false default keeps tests and previews
    /// on the Paris-only scatter their fixtures are calibrated against.
    /// `enforcesEdgePolicy` refuses a guest's call to a member route
    /// (`MockEdgePolicy`); the app passes true, tests opt in.
    public init(
        conditions: SimulatedConditions = .none,
        mediaCatalog: MockSocialDataset.MediaCatalog = .synthetic,
        seedsMapHierarchy: Bool = false,
        enforcesEdgePolicy: Bool = false
    ) {
        // The world beyond France (`MockWorldSeed`) rides the same decision
        // as the European seed: it is what the map's places are for.
        let dataset = Self.seededPostCount.map {
            MockSocialDataset(postCount: $0, mediaCatalog: mediaCatalog, seedsWorld: seedsMapHierarchy)
        } ?? MockSocialDataset(mediaCatalog: mediaCatalog, seedsWorld: seedsMapHierarchy)
        let counterStore = MockCounterStore(dataset: dataset)
        let blobStore = MockBlobStore()
        let postStore = MockPostStore()
        // `-mock-account-restricted` puts one active restriction on the viewer's
        // account, so Settings → Account Status can be seen in both states;
        // `-mock-report-history` gives the viewer past reports, one per outcome.
        let moderationService = MockModerationService(
            seedsViewerRestriction: ProcessInfo.processInfo.arguments.contains("-mock-account-restricted"),
            seedsReportHistory: ProcessInfo.processInfo.arguments.contains("-mock-report-history")
        )

        let bff = MockBFF()
        bff.simulatedConditions = conditions
        bff.enforcesEdgePolicy = enforcesEdgePolicy
        // One account lifecycle for both: step-up proofs minted by auth are
        // what account's gated RPCs check, and a deactivation made through
        // account is what the next auth login resumes.
        let accountLifecycle = MockAccountLifecycle()
        MockAuthService(lifecycle: accountLifecycle).register(on: bff)
        MockAccountService(lifecycle: accountLifecycle).register(on: bff)
        let socialServices = MockSocialServices(dataset: dataset, postStore: postStore)
        socialServices.register(on: bff)
        // Following a private profile asks (backend #655); profile.v1 owns
        // who is private. `-mock-follow-requests` seeds the viewer's inbox.
        let socialGraph = MockSocialGraphService(
            dataset: dataset,
            isPrivate: { socialServices.isPrivate($0) },
            seedsFollowRequests: ProcessInfo.processInfo.arguments.contains("-mock-follow-requests")
        )
        MockEngagementService(store: counterStore).register(on: bff)
        MockCounterService(store: counterStore).register(on: bff)
        MockMediaService(store: blobStore).register(on: bff)
        MockPostAuthoringService(store: postStore).register(on: bff)
        // A profile whose owner turned off "Show Up in Search" is left out (#412).
        MockSearchService(
            dataset: dataset,
            counters: counterStore,
            isFindable: { socialServices.isFindableInSearch($0) }
        ).register(on: bff)
        MockNotificationService(dataset: dataset).register(on: bff)
        // Comments matching a post owner's hidden words are dropped (#404),
        // and one outside the owner's "Who Can Comment" is refused (#397).
        MockCommentService(
            dataset: dataset,
            postStore: postStore,
            hiddenWords: { socialServices.hiddenWords(of: $0) },
            mayComment: { commenter, owner in
                switch socialServices.commentAudience(of: owner) {
                case .noOne: false
                case .followers: socialGraph.isFollowing(commenter, owner)
                case .mutuals: socialGraph.isFollowing(commenter, owner) && socialGraph.isFollowing(owner, commenter)
                default: true
                }
            }
        ).register(on: bff)
        MockChatService(dataset: dataset).register(on: bff)
        socialGraph.register(on: bff)
        let geoDiscovery = MockGeoDiscoveryService(dataset: dataset, spreadsHierarchy: seedsMapHierarchy)
        geoDiscovery.register(on: bff)
        moderationService.register(on: bff)

        self.dataset = dataset
        self.geoDiscovery = geoDiscovery
        self.counterStore = counterStore
        self.blobStore = blobStore
        self.postStore = postStore
        self.moderationService = moderationService
        self.bff = bff
    }

    /// A Connect client speaking binary proto against the fake edge. Mock
    /// routes don't verify bearer tokens, so the unauthenticated client is
    /// enough for previews and tests to feed generated service clients.
    public func makeRPCClient() -> ProtocolClientInterface {
        ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
    }

    /// `-mock-post-count <n>`: opt-in larger seeded corpus for QA (fills the
    /// map's hierarchy bands, which seed by default in mock mode).
    /// The DEFAULT (120, `MockSocialDataset.init`) must stay untouched:
    /// position-measured fixtures — the venue walk, the opening-viewport pin
    /// census, the pinned-category indexes — are calibrated against it, and
    /// tests construct their datasets directly so the argument never reaches
    /// them. Appending at the tail is the safe direction; this argument only
    /// ever changes `postCount`, never the head of the corpus. Clamped to
    /// 1...2000 (the scatter/venue arithmetic has no meaning past that, and a
    /// typo'd huge number should not hang the app seeding posts).
    private static var seededPostCount: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-mock-post-count"),
              arguments.indices.contains(position + 1),
              let count = Int(arguments[position + 1])
        else { return nil }
        return min(max(count, 1), 2000)
    }
}
