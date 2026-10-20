import Connect
import CoreContracts
import Foundation
import Testing
@testable import CoreNetworking
import CoreNetworkingMocks

/// The member's countries on the mock BFF (#1475): unlocked with the
/// wallet's gems, once, and listed.
struct MockCountryUnlockServiceTests {
    private struct MemberToken: AuthTokenProviding {
        func validAccessToken() async throws -> String? { "at-1" }
    }

    private func make() -> (GeoDiscovery_V1_GeoDiscoveryServiceClient, Wallet_V1_WalletServiceClient) {
        let bff = MockBFF()
        let dataset = MockSocialDataset()
        let store = MockCounterStore(dataset: dataset)
        let wallet = MockWalletService(store: store, dataset: dataset)
        wallet.register(on: bff)
        MockCountryUnlockService(wallet: wallet, homeCountry: "FR", seed: ["US"]).register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: MemberToken(), httpClient: bff
        )
        return (GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client), Wallet_V1_WalletServiceClient(client: client))
    }

    private func unlock(
        _ geo: GeoDiscovery_V1_GeoDiscoveryServiceClient, _ code: String, price: Int64
    ) async throws -> GeoDiscovery_V1_UnlockCountryResponse {
        var request = GeoDiscovery_V1_UnlockCountryRequest()
        request.accountID = MockAuthService.accountID
        request.countryCode = code
        request.expectedPrice = price
        return try #require(await geo.unlockCountry(request: request, headers: [:]).message)
    }

    @Test func theHomeAndTheSeedAreUnlockedFromTheStart() async throws {
        let (geo, _) = make()
        var request = GeoDiscovery_V1_GetCountryUnlocksRequest()
        request.accountID = MockAuthService.accountID
        let listed = try #require(await geo.getCountryUnlocks(request: request, headers: [:]).message)
        #expect(listed.homeCountry == "FR")
        #expect(listed.unlockedCountries == ["FR", "US"])
        #expect(listed.gems == 100)
    }

    /// An unlock spends the wallet's gems once and lists the country; one
    /// already open, or beyond the gems, charges nothing.
    @Test func anUnlockSpendsTheWalletsGemsOnce() async throws {
        let (geo, wallet) = make()
        let first = try await unlock(geo, "it", price: 30)
        #expect(first.outcome == .unlocked)
        #expect(first.gems == 70)
        #expect(first.unlockedCountries.contains("IT"))
        #expect(try await unlock(geo, "IT", price: 30).outcome == .alreadyUnlocked)
        #expect(try await unlock(geo, "FR", price: 0).outcome == .alreadyUnlocked)
        let short = try await unlock(geo, "JP", price: 500)
        #expect(short.outcome == .insufficientGems)
        #expect(short.gems == 70)

        var history = Wallet_V1_ListWalletTransactionsRequest()
        history.accountID = MockAuthService.accountID
        history.currency = .gems
        let rows = try #require(await wallet.listWalletTransactions(request: history, headers: [:]).message).transactions
        #expect(rows.first?.kind == .countryUnlock)
        #expect(rows.first?.delta == -30)
        #expect(rows.first?.refID == "IT")
    }
}
