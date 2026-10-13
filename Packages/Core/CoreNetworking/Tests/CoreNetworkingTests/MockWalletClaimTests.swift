import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import SwiftProtobuf
import Testing
@testable import CoreNetworking

private struct MemberToken: AuthTokenProviding {
    func validAccessToken() async throws -> String? { "at-1" }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

/// The mock wallet's GetWallet and ClaimReward (#1098), with the server's
/// claim rules, and the welcome gift it credits (#1008).
struct MockWalletClaimTests {
    private let dataset = MockSocialDataset()
    private let clock = Clock()
    private let account = MockAuthService.accountID

    private func make(startingPoints: Int64 = 250) -> (Wallet_V1_WalletServiceClient, MockWalletService) {
        let bff = MockBFF()
        let clock = clock
        let service = MockWalletService(
            store: MockCounterStore(dataset: dataset), dataset: dataset, startingPoints: startingPoints,
            now: { clock.now }
        )
        service.register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: MemberToken(), httpClient: bff
        )
        return (Wallet_V1_WalletServiceClient(client: client), service)
    }

    private func wallet(_ client: Wallet_V1_WalletServiceClient) async throws -> Wallet_V1_Wallet {
        var request = Wallet_V1_GetWalletRequest()
        request.accountID = account
        return try #require(await client.getWallet(request: request, headers: [:]).message)
    }

    private func claim(_ client: Wallet_V1_WalletServiceClient, key: String) async throws -> Wallet_V1_ClaimRewardResponse {
        var request = Wallet_V1_ClaimRewardRequest()
        request.accountID = account
        request.idempotencyKey = key
        return try #require(await client.claimReward(request: request, headers: [:]).message)
    }

    @Test func aNewWalletOpensAtItsStartWithTheClaimOpen() async throws {
        let (client, _) = make()
        let opened = try await wallet(client)
        #expect(opened.points == 250)
        #expect(opened.claimAvailable)
        #expect(opened.claimAmount == 25)
        #expect(!opened.hasNextClaimAt)
        #expect(opened.pointsCap == MockWalletService.pointsCap)
    }

    /// A claim pays, then the next one waits an hour — in-band, with the
    /// wallet saying when.
    @Test func aClaimPaysThenTheNextWaitsAnHour() async throws {
        let (client, _) = make()
        let first = try await claim(client, key: "claim-key-0001")
        #expect(first.outcome == .claimed)
        #expect(first.awarded == 25)
        #expect(first.wallet.points == 275)

        let second = try await claim(client, key: "claim-key-0002")
        #expect(second.outcome == .tooEarly)
        #expect(second.wallet.nextClaimAt.date == clock.now.addingTimeInterval(3_600))

        clock.now = clock.now.addingTimeInterval(3_600)
        #expect(try await claim(client, key: "claim-key-0003").outcome == .claimed)
    }

    /// A retry of a key pays once, and answers what it answered.
    @Test func aRetriedKeyPaysOnce() async throws {
        let (client, _) = make()
        _ = try await claim(client, key: "claim-key-0004")
        let replay = try await claim(client, key: "claim-key-0004")
        #expect(replay.outcome == .claimed)
        #expect(replay.wallet.points == 275)
    }

    /// At the points cap: BALANCE_FULL, and no countdown — only spending
    /// opens it again.
    @Test func aFullWalletAnswersBalanceFull() async throws {
        let (client, _) = make(startingPoints: MockWalletService.pointsCap)
        let answer = try await claim(client, key: "claim-key-0005")
        #expect(answer.outcome == .balanceFull)
        #expect(!answer.wallet.claimAvailable)
        #expect(!answer.wallet.hasNextClaimAt)
    }

    @Test func aKeyOutsideTheContractIsRefused() async throws {
        let (client, _) = make()
        var request = Wallet_V1_ClaimRewardRequest()
        request.accountID = account
        request.idempotencyKey = "short"
        #expect(await client.claimReward(request: request, headers: [:]).error?.code == .invalidArgument)
    }

    /// The welcome gift: once per device, from its first launch.
    @Test func theWelcomeGiftIsCreditedOncePerDevice() async throws {
        let (client, service) = make()
        let twoDaysAgo = clock.now.addingTimeInterval(-2 * 86_400 - 60)
        #expect(service.creditWelcomeGift(account: account, device: "dev-1", firstLaunch: twoDaysAgo) == 100)
        #expect(service.creditWelcomeGift(account: account, device: "dev-1", firstLaunch: twoDaysAgo) == 0)
        #expect(try await wallet(client).points == 350)
    }
}
