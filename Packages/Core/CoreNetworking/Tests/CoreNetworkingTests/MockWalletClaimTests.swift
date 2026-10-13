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

    private func make(
        startingPoints: Int64 = 250, demoPositions: [String] = []
    ) -> (Wallet_V1_WalletServiceClient, MockWalletService) {
        let bff = MockBFF()
        let clock = clock
        let service = MockWalletService(
            store: MockCounterStore(dataset: dataset), dataset: dataset, startingPoints: startingPoints,
            demoPositions: demoPositions, now: { clock.now }
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

    /// ListMyStakes (#903): a stake opens a position; a day later it is
    /// settled, PENDING for its first hour, and listed under SETTLED.
    @Test func aStakeIsListedActiveThenSettled() async throws {
        let (client, _) = make()
        let post = try #require(dataset.posts.first { dataset.accountID(for: $0.authorProfileID) != account }).postID
        var stake = Wallet_V1_StakeRequest()
        stake.accountID = account
        stake.profileID = MockSocialDataset.viewerProfileID
        stake.postID = post
        stake.points = 3
        stake.idempotencyKey = "stake-key-0001"
        stake.firstTapAt = Google_Protobuf_Timestamp(date: clock.now)
        #expect(await client.stake(request: stake, headers: [:]).message?.outcome == .staked)

        func list(_ status: Wallet_V1_StakeStatusFilter) async throws -> [Wallet_V1_MyStake] {
            var request = Wallet_V1_ListMyStakesRequest()
            request.accountID = account
            request.status = status
            return try #require(await client.listMyStakes(request: request, headers: [:]).message).stakes
        }
        let active = try await list(.active)
        #expect(active.map(\.postID) == [post])
        #expect(active.first?.points == 3)
        #expect(active.first?.hasSettledAt == false)

        clock.now = clock.now.addingTimeInterval(24 * 3_600 + 60)
        #expect(try await list(.active).isEmpty)
        let settled = try await list(.settled)
        #expect(settled.first?.verdict == .pending)
        clock.now = clock.now.addingTimeInterval(3_600)
        #expect(try await list(.settled).first.map { [.rewarded, .notRewarded].contains($0.verdict) } == true)
    }

    /// The pages follow the token, newest first stake first.
    @Test func theStakesPage() async throws {
        let posts = dataset.posts.prefix(5).map(\.postID)
        let (client, _) = make(demoPositions: posts)
        var request = Wallet_V1_ListMyStakesRequest()
        request.accountID = account
        request.pageSize = 2
        var ids: [String] = []
        var token = ""
        repeat {
            request.pageToken = token
            let page = try #require(await client.listMyStakes(request: request, headers: [:]).message)
            ids += page.stakes.map(\.postID)
            token = page.nextPageToken
        } while !token.isEmpty
        #expect(ids == posts)
    }

    /// ListWalletTransactions (#400): the ledger newest first — a claim, a
    /// stake, the opening gifts — by currency.
    @Test func theHistoryListsEveryMovementNewestFirst() async throws {
        let (client, _) = make()
        _ = try await claim(client, key: "claim-key-0100")
        let post = try #require(dataset.posts.first { dataset.accountID(for: $0.authorProfileID) != account }).postID
        var stake = Wallet_V1_StakeRequest()
        stake.accountID = account
        stake.profileID = MockSocialDataset.viewerProfileID
        stake.postID = post
        stake.points = 4
        stake.idempotencyKey = "stake-key-0100"
        stake.firstTapAt = Google_Protobuf_Timestamp(date: clock.now)
        _ = await client.stake(request: stake, headers: [:])

        func history(_ currency: Wallet_V1_Currency) async throws -> [Wallet_V1_WalletTransaction] {
            var request = Wallet_V1_ListWalletTransactionsRequest()
            request.accountID = account
            request.currency = currency
            return try #require(await client.listWalletTransactions(request: request, headers: [:]).message).transactions
        }
        let points = try await history(.points)
        #expect(points.map(\.kind) == [.stake, .claim, .starterGift])
        #expect(points.map(\.delta) == [-4, 25, 250])
        #expect(points.first?.balanceAfter == 271)
        #expect(try await history(.gems).map(\.kind) == [.starterGift])
        #expect(try await history(.unspecified).count == 4)
    }
}
