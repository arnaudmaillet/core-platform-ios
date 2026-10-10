import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// `blockedProfiles()` reads the whole block list through `TokenPager`: the
/// first page with an empty token, the next with the token it handed back,
/// and no further once a page ends the list. The mock's own `ListBlocks`
/// never pages, so this suite serves its two pages itself.
struct BlockedProfilesPagingTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    /// Every page token `ListBlocks` was asked with, in order.
    private final class AskedTokens: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String] = []
        func append(_ token: String) { lock.withLock { tokens.append(token) } }
        var all: [String] { lock.withLock { tokens } }
    }

    private static func block(_ id: String) -> SocialGraph_V1_BlockSummary {
        var summary = SocialGraph_V1_BlockSummary()
        summary.blockeeID = id
        return summary
    }

    @Test func readsBothPagesInOrderAndStopsOnTheEmptyToken() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        // Registered last, so it answers `ListBlocks` instead of the mock's.
        let asked = AskedTokens()
        bff.register(path: "/social_graph.v1.SocialGraphService/ListBlocks") {
            (request: SocialGraph_V1_ListBlocksRequest) -> Result<SocialGraph_V1_ListBlocksResponse, ConnectError> in
            asked.append(request.pageToken)
            var response = SocialGraph_V1_ListBlocksResponse()
            switch request.pageToken {
            case "":
                response.blocks = [Self.block("prof-3")]
                response.nextPageToken = "page-2"
            case "page-2":
                response.blocks = [Self.block("prof-4")]
            default:
                return .failure(ConnectError(code: .invalidArgument, message: "unexpected token"))
            }
            return .success(response)
        }
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )

        let blocked = try await repository.blockedProfiles()

        #expect(blocked.map(\.id.rawValue) == ["prof-3", "prof-4"])
        #expect(asked.all == ["", "page-2"])
    }
}
