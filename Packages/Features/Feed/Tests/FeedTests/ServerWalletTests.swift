import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Feed

private struct WalletSession: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private struct WalletMemberToken: AuthTokenProviding {
    func validAccessToken() async throws -> String? { "at-1" }
}

/// The store, over the edge to the mock wallet (#1098).
struct ServerWalletTests {
    @Test func theStoreShowsAndClaimsTheServersWallet() async {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let service = MockWalletService(store: MockCounterStore(dataset: dataset), dataset: dataset, startingPoints: 250)
        service.register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: WalletMemberToken(), httpClient: bff
        )
        let viewer = ViewerSession(authSession: WalletSession()) { _ in [ProfileID(MockSocialDataset.viewerProfileID)] }
        let store = WalletStore(
            defaults: UserDefaults(suiteName: "server-wallet-\(UUID().uuidString)")!,
            scope: StorageScope(owner: .member(account: MockAuthService.accountID, profile: MockSocialDataset.viewerProfileID))
        )
        store.server = ServerWallet(walletClient: Wallet_V1_WalletServiceClient(client: client), viewer: viewer)

        #expect(await store.refreshFromServer())
        #expect(store.balance == 250)
        #expect(store.snapshot().claimAvailable)

        #expect(await store.claim(idempotencyKey: "tap-key-0001") == .claimed(awarded: 25))
        #expect(store.balance == 275)
        #expect(await store.claim(idempotencyKey: "tap-key-0002") != .claimed(awarded: 25))
        #expect(service.points(of: MockAuthService.accountID) == 275)
    }
}
