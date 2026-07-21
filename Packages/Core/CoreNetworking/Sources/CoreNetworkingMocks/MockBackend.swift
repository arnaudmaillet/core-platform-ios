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
    public let bff: MockBFF

    public init(conditions: SimulatedConditions = .none) {
        let dataset = MockSocialDataset()
        let counterStore = MockCounterStore(dataset: dataset)
        let blobStore = MockBlobStore()
        let postStore = MockPostStore()

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
        MockGeoDiscoveryService(dataset: dataset).register(on: bff)

        self.dataset = dataset
        self.counterStore = counterStore
        self.blobStore = blobStore
        self.postStore = postStore
        self.bff = bff
    }

    /// A Connect client speaking binary proto against the fake edge. Mock
    /// routes don't verify bearer tokens, so the unauthenticated client is
    /// enough for previews and tests to feed generated service clients.
    public func makeRPCClient() -> ProtocolClientInterface {
        ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
    }
}
