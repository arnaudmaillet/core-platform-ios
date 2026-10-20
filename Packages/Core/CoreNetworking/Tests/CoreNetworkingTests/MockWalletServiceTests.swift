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

/// The mock's like path (#676): `wallet.Stake` with the server's rules, read
/// back by engagement's `BatchGetLikes`.
struct MockWalletServiceTests {
    private let dataset = MockSocialDataset()
    private let clock = Clock()

    private func make() -> (Wallet_V1_WalletServiceClient, Engagement_V1_EngagementServiceClient, MockCounterStore) {
        let bff = MockBFF()
        let store = MockCounterStore(dataset: dataset)
        MockEngagementService(store: store).register(on: bff)
        let clock = clock
        MockWalletService(store: store, dataset: dataset, now: { clock.now }).register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: MemberToken(), httpClient: bff
        )
        return (Wallet_V1_WalletServiceClient(client: client), Engagement_V1_EngagementServiceClient(client: client), store)
    }

    /// A post the viewer did not write.
    private var someoneElsesPost: String {
        dataset.posts.first { dataset.accountID(for: $0.authorProfileID) != MockAuthService.accountID }!.postID
    }

    private func stake(
        _ wallet: Wallet_V1_WalletServiceClient, post: String, likes: Int32,
        key: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        firstTapAt: Date? = nil, shot: Bool = false
    ) async throws -> Wallet_V1_StakeResponse {
        var request = Wallet_V1_StakeRequest()
        request.accountID = MockAuthService.accountID
        request.profileID = MockSocialDataset.viewerProfileID
        request.postID = post
        request.points = likes
        request.useStakeShot = shot
        request.idempotencyKey = key
        request.firstTapAt = Google_Protobuf_Timestamp(date: firstTapAt ?? clock.now)
        let response = await wallet.stake(request: request, headers: [:])
        return try #require(response.message, "\(String(describing: response.error))")
    }

    @Test func aBatchStakesItsPointsAndTheCountReadsThemBack() async throws {
        let (wallet, engagement, store) = make()
        let post = someoneElsesPost
        let before = store.likeCount(for: post)
        let answer = try await stake(wallet, post: post, likes: 3)
        #expect(answer.outcome == .staked)
        #expect(answer.spent == 3)
        #expect(answer.myTotal == 3)

        var target = Engagement_V1_LikeTarget()
        target.postID = post
        var read = Engagement_V1_BatchGetLikesRequest()
        read.targets = [target]
        let view = try #require(await engagement.batchGetLikes(request: read, headers: [:]).message?.likes.first)
        #expect(view.count == before + 3)
        #expect(view.mine == 3)
    }

    /// A retried key is answered once: nothing is spent twice.
    @Test func aReplayedKeySpendsNothingMore() async throws {
        let (wallet, _, store) = make()
        let post = someoneElsesPost
        let before = store.likeCount(for: post)
        _ = try await stake(wallet, post: post, likes: 2, key: "batch-replay-1")
        let replay = try await stake(wallet, post: post, likes: 2, key: "batch-replay-1")
        #expect(replay.spent == 2)
        #expect(store.likeCount(for: post) == before + 2)
    }

    /// 250 likes per account and post, ever: clamped, then refused.
    @Test func theTargetsRoomClampsThenRefuses() async throws {
        let (wallet, _, _) = make()
        let post = someoneElsesPost
        _ = try await stake(wallet, post: post, likes: 240)
        let clamped = try await stake(wallet, post: post, likes: 20)
        #expect(clamped.outcome == .staked)
        #expect(clamped.spent == 10)
        #expect(clamped.myTotal == 250)
        #expect(try await stake(wallet, post: post, likes: 1).outcome == .targetCapReached)
    }

    /// A shot needs room for a whole 100.
    @Test func aShotThatDoesNotFitIsRefused() async throws {
        let (wallet, _, _) = make()
        let post = someoneElsesPost
        #expect(try await buyPack(wallet).outcome == .bought)
        _ = try await stake(wallet, post: post, likes: 200)
        #expect(try await stake(wallet, post: post, likes: 0, shot: true).outcome == .shotDoesNotFit)
    }

    // MARK: Spending gems (#1475)

    private func newKey() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    private func buyPack(
        _ wallet: Wallet_V1_WalletServiceClient, packID: String = "", key: String? = nil
    ) async throws -> Wallet_V1_BuyStakePackResponse {
        var request = Wallet_V1_BuyStakePackRequest()
        request.accountID = MockAuthService.accountID
        request.packID = packID
        request.idempotencyKey = key ?? newKey()
        return try #require(await wallet.buyStakePack(request: request, headers: [:]).message)
    }

    private func purchase(
        _ wallet: Wallet_V1_WalletServiceClient, item: String, price: Int64, key: String? = nil
    ) async throws -> Wallet_V1_PurchaseItemResponse {
        var request = Wallet_V1_PurchaseItemRequest()
        request.accountID = MockAuthService.accountID
        request.itemID = item
        request.expectedPrice = price
        request.idempotencyKey = key ?? newKey()
        return try #require(await wallet.purchaseItem(request: request, headers: [:]).message)
    }

    /// A pack costs its gems once, loads its shots, and does not stack; a
    /// shot spends one of them, and none left fires none.
    @Test func aPackIsBoughtOnceAndItsShotsAreTheServers() async throws {
        let (wallet, _, _) = make()
        let key = newKey()
        let bought = try await buyPack(wallet, key: key)
        #expect(bought.outcome == .bought)
        #expect(bought.wallet.gems == 50)
        #expect(bought.wallet.stakeShots == 3)
        #expect(bought.wallet.stakePackID == "shots_3")
        // A retry with the same key charges nothing more.
        let replay = try await buyPack(wallet, key: key)
        #expect(replay.outcome == .bought)
        #expect(replay.wallet.gems == 50)
        #expect(try await buyPack(wallet).outcome == .packStillActive)

        let post = someoneElsesPost
        #expect(try await stake(wallet, post: post, likes: 0, shot: true).outcome == .staked)
        var read = Wallet_V1_GetWalletRequest()
        read.accountID = MockAuthService.accountID
        #expect(try #require(await wallet.getWallet(request: read, headers: [:]).message).stakeShots == 2)
    }

    @Test func noPackNoShot() async throws {
        let (wallet, _, _) = make()
        #expect(try await stake(wallet, post: someoneElsesPost, likes: 0, shot: true).outcome == .noStakeShots)
    }

    @Test func aPackBeyondTheGemsIsRefused() async throws {
        let (wallet, _, _) = make()
        let answer = try await buyPack(wallet, packID: "shots_10")
        #expect(answer.outcome == .insufficientGems)
        #expect(answer.wallet.gems == 100)
        #expect(answer.wallet.stakeShots == 0)
    }

    /// A catalogue item: bought once at its price, then owned; another price
    /// or too few gems charge nothing; free ones are owned by everyone.
    @Test func aCatalogueItemIsBoughtOnceAndOwned() async throws {
        let (wallet, _, _) = make()
        #expect(try await purchase(wallet, item: "theme.violet", price: 40).outcome == .priceChanged)
        #expect(try await purchase(wallet, item: "banner.animated", price: 500).outcome == .insufficientGems)
        #expect(try await purchase(wallet, item: "theme.pink", price: 0).outcome == .alreadyOwned)
        #expect(try await purchase(wallet, item: "theme.teal", price: 50).outcome == .unknownItem)
        let key = newKey()
        let bought = try await purchase(wallet, item: "theme.violet", price: 50, key: key)
        #expect(bought.outcome == .purchased)
        #expect(bought.wallet.gems == 50)
        #expect(try await purchase(wallet, item: "theme.violet", price: 50, key: key).wallet.gems == 50, "a retry charges once")
        #expect(try await purchase(wallet, item: "theme.violet", price: 50).outcome == .alreadyOwned)

        var owned = Wallet_V1_ListOwnedItemsRequest()
        owned.accountID = MockAuthService.accountID
        let items = try #require(await wallet.listOwnedItems(request: owned, headers: [:]).message).items.map(\.itemID)
        #expect(items == ["theme.pink", "theme.violet"])
        let catalog = try #require(await wallet.listCatalog(request: Wallet_V1_ListCatalogRequest(), headers: [:]).message)
        #expect(catalog.items.first { $0.itemID == "banner.animated" }?.price == 500)
        #expect(catalog.items.first { $0.itemID == "theme.red" }?.family == .theme)
    }

    @Test func aBatchOverADayOldExpires() async throws {
        let (wallet, _, _) = make()
        let answer = try await stake(
            wallet, post: someoneElsesPost, likes: 1, firstTapAt: clock.now.addingTimeInterval(-25 * 3600)
        )
        #expect(answer.outcome == .expired)
        #expect(answer.spent == 0)
    }

    @Test func onesOwnPostIsRefused() async throws {
        let (wallet, _, _) = make()
        let own = try #require(dataset.posts.first {
            dataset.accountID(for: $0.authorProfileID) == MockAuthService.accountID
        }).postID
        #expect(try await stake(wallet, post: own, likes: 1).outcome == .ownContent)
    }

    /// 1,000 likes an hour.
    @Test func theHoursRoomLimitsSpending() async throws {
        let (wallet, _, _) = make()
        let posts = dataset.posts.filter { dataset.accountID(for: $0.authorProfileID) != MockAuthService.accountID }
        for post in posts.prefix(4) { _ = try await stake(wallet, post: post.postID, likes: 250) }
        let fifth = posts[4].postID
        #expect(try await stake(wallet, post: fifth, likes: 1).outcome == .rateLimited)
        clock.now = clock.now.addingTimeInterval(3601)
        #expect(try await stake(wallet, post: fifth, likes: 1).outcome == .staked)
    }
}
