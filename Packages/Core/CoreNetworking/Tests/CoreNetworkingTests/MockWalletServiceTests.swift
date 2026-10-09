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
        _ wallet: Wallet_V1_WalletServiceClient, post: String, points: Int32,
        key: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        firstTapAt: Date? = nil, shot: Bool = false
    ) async throws -> Wallet_V1_StakeResponse {
        var request = Wallet_V1_StakeRequest()
        request.accountID = MockAuthService.accountID
        request.profileID = MockSocialDataset.viewerProfileID
        request.postID = post
        request.points = points
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
        let answer = try await stake(wallet, post: post, points: 3)
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
        _ = try await stake(wallet, post: post, points: 2, key: "batch-replay-1")
        let replay = try await stake(wallet, post: post, points: 2, key: "batch-replay-1")
        #expect(replay.spent == 2)
        #expect(store.likeCount(for: post) == before + 2)
    }

    /// 250 points per account and post, ever: clamped, then refused.
    @Test func theTargetsRoomClampsThenRefuses() async throws {
        let (wallet, _, _) = make()
        let post = someoneElsesPost
        _ = try await stake(wallet, post: post, points: 240)
        let clamped = try await stake(wallet, post: post, points: 20)
        #expect(clamped.outcome == .staked)
        #expect(clamped.spent == 10)
        #expect(clamped.myTotal == 250)
        #expect(try await stake(wallet, post: post, points: 1).outcome == .targetCapReached)
    }

    /// A shot needs room for a whole 100.
    @Test func aShotThatDoesNotFitIsRefused() async throws {
        let (wallet, _, _) = make()
        let post = someoneElsesPost
        _ = try await stake(wallet, post: post, points: 200)
        #expect(try await stake(wallet, post: post, points: 0, shot: true).outcome == .shotDoesNotFit)
    }

    @Test func aBatchOverADayOldExpires() async throws {
        let (wallet, _, _) = make()
        let answer = try await stake(
            wallet, post: someoneElsesPost, points: 1, firstTapAt: clock.now.addingTimeInterval(-25 * 3600)
        )
        #expect(answer.outcome == .expired)
        #expect(answer.spent == 0)
    }

    @Test func onesOwnPostIsRefused() async throws {
        let (wallet, _, _) = make()
        let own = try #require(dataset.posts.first {
            dataset.accountID(for: $0.authorProfileID) == MockAuthService.accountID
        }).postID
        #expect(try await stake(wallet, post: own, points: 1).outcome == .ownContent)
    }

    /// 1,000 points an hour.
    @Test func theHoursRoomLimitsSpending() async throws {
        let (wallet, _, _) = make()
        let posts = dataset.posts.filter { dataset.accountID(for: $0.authorProfileID) != MockAuthService.accountID }
        for post in posts.prefix(4) { _ = try await stake(wallet, post: post.postID, points: 250) }
        let fifth = posts[4].postID
        #expect(try await stake(wallet, post: fifth, points: 1).outcome == .rateLimited)
        clock.now = clock.now.addingTimeInterval(3601)
        #expect(try await stake(wallet, post: fifth, points: 1).outcome == .staked)
    }
}
