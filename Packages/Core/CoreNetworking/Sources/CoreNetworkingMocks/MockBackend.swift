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
    /// geo anchors (`MockGeoDiscoveryService`) — the app passes true in mock
    /// mode (semantic map clusters are the default experience, opt out with
    /// `-maps-mock-no-places`); the false default keeps tests and previews
    /// on the Paris-only scatter their fixtures are calibrated against.
    public init(
        conditions: SimulatedConditions = .none,
        mediaCatalog: MockSocialDataset.MediaCatalog = .synthetic,
        seedsMapHierarchy: Bool = false
    ) {
        let dataset = Self.seededPostCount.map {
            MockSocialDataset(postCount: $0, mediaCatalog: mediaCatalog)
        } ?? MockSocialDataset(mediaCatalog: mediaCatalog)
        let counterStore = MockCounterStore(dataset: dataset)
        let blobStore = MockBlobStore()
        let postStore = MockPostStore()
        let moderationService = MockModerationService()

        let bff = MockBFF()
        bff.simulatedConditions = conditions
        MockAuthService().register(on: bff)
        MockAccountService().register(on: bff)
        MockSocialServices(dataset: dataset, postStore: postStore).register(on: bff)
        MockEngagementService(store: counterStore).register(on: bff)
        MockCounterService(store: counterStore).register(on: bff)
        MockMediaService(store: blobStore).register(on: bff)
        MockPostAuthoringService(store: postStore).register(on: bff)
        MockSearchService(dataset: dataset).register(on: bff)
        MockNotificationService(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockGeoDiscoveryService(dataset: dataset, spreadsHierarchy: seedsMapHierarchy)
            .register(on: bff)
        moderationService.register(on: bff)

        self.dataset = dataset
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
