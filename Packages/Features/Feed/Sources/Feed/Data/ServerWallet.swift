import AuthInterface
import CoreContracts
import CoreNetworking
import CoreStorage
import Foundation
import SwiftProtobuf

/// The member's wallet over the edge (#1098): wallet.v1 `GetWallet` and
/// `ClaimReward`, as the signed-in account. Never a guest's — every wallet
/// RPC refuses a guest token, and a guest's likes are the welcome gift's.
public actor ServerWallet: WalletServer {
    private let walletClient: any Wallet_V1_WalletServiceClientInterface
    private let viewer: any ViewerProviding

    public init(walletClient: any Wallet_V1_WalletServiceClientInterface, viewer: any ViewerProviding) {
        self.walletClient = walletClient
        self.viewer = viewer
    }

    /// Asked of a guest, or before anyone is signed in.
    public struct NotAMember: Error, Equatable {}

    public func wallet() async throws -> WalletServerState {
        var request = Wallet_V1_GetWalletRequest()
        request.accountID = try await account()
        let response = await walletClient.getWallet(request: request, headers: [:])
        if let error = response.error { throw NetworkFailureError(NetworkFailure(error)) }
        guard let wallet = response.message else { throw NetworkFailureError(.server(code: "empty_response")) }
        return Self.state(wallet)
    }

    public func claim(idempotencyKey: String) async throws -> (outcome: WalletClaimOutcome, wallet: WalletServerState) {
        var request = Wallet_V1_ClaimRewardRequest()
        request.accountID = try await account()
        request.idempotencyKey = idempotencyKey
        let response = await walletClient.claimReward(request: request, headers: [:])
        if let error = response.error { throw NetworkFailureError(NetworkFailure(error)) }
        guard let answer = response.message else { throw NetworkFailureError(.server(code: "empty_response")) }
        let state = Self.state(answer.wallet)
        let outcome: WalletClaimOutcome = switch answer.outcome {
        case .claimed: .claimed(awarded: Int(answer.awarded))
        case .tooEarly: .tooEarly(nextClaimAt: state.nextClaimAt ?? Date())
        case .dailyCapReached: .dailyCapReached
        case .balanceFull: .balanceFull
        case .unspecified, .UNRECOGNIZED: .unavailable
        }
        return (outcome, state)
    }

    private func account() async throws -> String {
        guard case .member(let account, _) = await viewer.current() else { throw NotAMember() }
        return account.rawValue
    }

    /// The wire's wallet, as the store keeps it.
    static func state(_ wallet: Wallet_V1_Wallet) -> WalletServerState {
        WalletServerState(
            points: Int(clamping: wallet.points),
            claimAvailable: wallet.claimAvailable,
            nextClaimAt: wallet.hasNextClaimAt ? wallet.nextClaimAt.date : nil,
            claimAmount: Int(wallet.claimAmount),
            claimedToday: Int(wallet.claimedToday),
            dailyClaimCap: Int(wallet.dailyClaimCap),
            streakDays: Int(wallet.streakDays),
            pointsCap: Int(clamping: wallet.pointsCap)
        )
    }
}

/// A wallet call that failed on the way (#794): why, for the copy.
public struct NetworkFailureError: NetworkFailureCarrying, Equatable {
    public let failure: NetworkFailure
    public var networkFailure: NetworkFailure? { failure }

    public init(_ failure: NetworkFailure) {
        self.failure = failure
    }
}
