import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Feed

private struct MemberSession: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private struct BearerToken: AuthTokenProviding {
    func validAccessToken() async throws -> String? { "at-1" }
}

/// How `wallet.Stake`'s answers sort into "drop", "wait" and "retry" (#796).
struct WalletLikeStakingTests {
    private func makeStaking(answering code: Code?) -> (WalletLikeStaking, MockBFF) {
        let bff = MockBFF()
        bff.register(path: "/wallet.v1.WalletService/Stake") { (_: Wallet_V1_StakeRequest) -> Result<Wallet_V1_StakeResponse, ConnectError> in
            if let code { return .failure(ConnectError(code: code, message: "refused")) }
            var response = Wallet_V1_StakeResponse()
            response.outcome = .staked
            response.spent = 1
            response.myTotal = 1
            return .success(response)
        }
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: BearerToken(), httpClient: bff
        )
        let viewer = ViewerSession(authSession: MemberSession()) { _ in [ProfileID("profile-1")] }
        return (WalletLikeStaking(walletClient: Wallet_V1_WalletServiceClient(client: client), viewer: viewer), bff)
    }

    private func batch(account: String? = MockAuthService.accountID) -> LikeOutbox.Batch {
        LikeOutbox.Batch(
            target: .post("p1"), points: 1, usesStakeShot: false, idempotencyKey: "key-0001",
            firstTapAt: Date(), lastTapAt: Date(), isSealed: true, accountID: account, profileID: "profile-1"
        )
    }

    @Test func aRequestTheServerRefusesForGoodIsRejected() async {
        for code in [Code.invalidArgument, .notFound, .failedPrecondition] {
            let (staking, _) = makeStaking(answering: code)
            await #expect(throws: LikeStakeRejected.self, "\(code) was retried forever") {
                try await staking.stake(batch())
            }
        }
    }

    /// ⚠️ `permissionDenied` MAY CURE ITSELF: a profile newer than the access
    /// token is refused until the next refresh, so the batch is retried.
    @Test func aLostConnectionOrAStaleTokenIsRetried() async {
        for code in [Code.unavailable, .deadlineExceeded, .permissionDenied] {
            let (staking, _) = makeStaking(answering: code)
            await #expect(throws: FeedError.self, "\(code) was not retried") {
                try await staking.stake(batch())
            }
        }
    }

    /// The retried error keeps WHY (#794): a lost connection reads offline,
    /// a timeout a timeout. The mock's own switchboard, never a shared one.
    @Test func aRetriedStakeKeepsWhyItFailed() async {
        let (staking, bff) = makeStaking(answering: .deadlineExceeded)
        let timedOut = await #expect(throws: FeedError.self) { try await staking.stake(batch()) }
        #expect(timedOut?.networkFailure == .timeout)

        let faults = MockNetworkFaults()
        faults.isForcedOffline = true
        bff.faults = faults
        let offline = await #expect(throws: FeedError.self) { try await staking.stake(batch()) }
        #expect(offline?.networkFailure == .offline)
    }

    /// ⚠️ ANOTHER ACCOUNT'S BATCH IS NEVER SENT with this account's token: the
    /// server would refuse it, and the refund would land in the wrong wallet.
    @Test func anotherAccountsBatchWaitsWithoutBeingSent() async {
        let (staking, bff) = makeStaking(answering: nil)
        await #expect(throws: LikeStakeNotNow.self) {
            try await staking.stake(batch(account: "someone-else"))
        }
        #expect(!bff.recordedRequests.contains { $0.path == "/wallet.v1.WalletService/Stake" })
    }

    @Test func thisAccountsBatchGoes() async throws {
        let (staking, _) = makeStaking(answering: nil)
        let answer = try await staking.stake(batch())
        #expect(answer == LikeStakeAnswer(outcome: .staked, spent: 1, myTotal: 1))
    }
}
