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

    /// Pages followed when listing the stakes (100 each).
    static let stakePages = 5

    /// Every stake on a post, active and settled, newest first stake first
    /// (#903). Comment stakes are left out: the sheet lists posts.
    public func myStakes() async throws -> [WalletStake] {
        let account = try await self.account()
        var stakes: [WalletStake] = []
        var token = ""
        for _ in 0..<Self.stakePages {
            var request = Wallet_V1_ListMyStakesRequest()
            request.accountID = account
            request.pageSize = 100
            request.pageToken = token
            let response = await walletClient.listMyStakes(request: request, headers: [:])
            if let error = response.error { throw NetworkFailureError(NetworkFailure(error)) }
            guard let page = response.message else { break }
            stakes += page.stakes.compactMap(Self.stake)
            token = page.nextPageToken
            if token.isEmpty { break }
        }
        return stakes
    }

    /// The wire's stake, as the sheet lists it: settled with the server's
    /// verdict alone — no gems while settlement runs in shadow mode.
    static func stake(_ stake: Wallet_V1_MyStake) -> WalletStake? {
        guard case .postID(let postID)? = stake.target else { return nil }
        let outcome: WalletStake.Outcome?
        if stake.hasSettledAt {
            outcome = switch stake.verdict {
            case .rewarded: .rewarded
            case .notRewarded: .notRewarded
            case .pending, .unspecified, .UNRECOGNIZED: .pending
            }
        } else {
            outcome = nil
        }
        let first = stake.hasFirstAt ? stake.firstAt.date : Date()
        return WalletStake(
            targetID: postID,
            amount: Int(clamping: stake.points),
            stakedAt: first,
            settlesAt: stake.hasSettlesAt ? stake.settlesAt.date : first.addingTimeInterval(24 * 3_600),
            outcome: outcome
        )
    }

    /// A page of the wallet's history (#400), newest first.
    public func transactions(
        currency: WalletTransaction.Currency?, after pageToken: String?
    ) async throws -> WalletTransactionPage {
        var request = Wallet_V1_ListWalletTransactionsRequest()
        request.accountID = try await account()
        request.currency = switch currency {
        case .likes?: .points
        case .gems?: .gems
        case nil: .unspecified
        }
        request.pageSize = 50
        request.pageToken = pageToken ?? ""
        let response = await walletClient.listWalletTransactions(request: request, headers: [:])
        if let error = response.error { throw NetworkFailureError(NetworkFailure(error)) }
        guard let page = response.message else { throw NetworkFailureError(.server(code: "empty_response")) }
        return WalletTransactionPage(
            transactions: page.transactions.map(Self.transaction),
            nextPageToken: page.nextPageToken.isEmpty ? nil : page.nextPageToken
        )
    }

    static func transaction(_ wire: Wallet_V1_WalletTransaction) -> WalletTransaction {
        let kind: WalletTransaction.Kind = switch wire.kind {
        case .claim: .claim
        case .starterGift: .starterGift
        case .stakePack: .stakePack
        case .countryUnlock: .countryUnlock
        case .stake: .stake
        case .welcomeGift: .welcomeGift
        case .appIcon: .appIcon
        case .theme: .theme
        case .countryVisa: .countryVisa
        case .profileSlot: .profileSlot
        case .handleChange: .handleChange
        case .avatarFrame: .avatarFrame
        case .animatedBanner: .animatedBanner
        case .cardStyle: .cardStyle
        case .animatedAvatar: .animatedAvatar
        case .unspecified, .UNRECOGNIZED: .other
        }
        return WalletTransaction(
            id: wire.transactionID,
            currency: wire.currency == .gems ? .gems : .likes,
            delta: Int(clamping: wire.delta),
            balanceAfter: Int(clamping: wire.balanceAfter),
            kind: kind,
            createdAt: wire.hasCreatedAt ? wire.createdAt.date : nil,
            reference: wire.refID.isEmpty ? nil : wire.refID
        )
    }

    private func account() async throws -> String {
        guard case .member(let account, _) = await viewer.current() else { throw NotAMember() }
        return account.rawValue
    }

    /// The wire's wallet, as the store keeps it.
    static func state(_ wallet: Wallet_V1_Wallet) -> WalletServerState {
        // The packs on sale (#941); an older server's one default pack.
        var packs = wallet.stakePacks.map {
            WalletStore.Policy.StakePack.Tier(id: $0.packID, shots: Int($0.shots), price: Int(clamping: $0.price))
        }
        if packs.isEmpty, wallet.stakePackShots > 0 {
            packs = [WalletStore.Policy.StakePack.Tier(
                id: "shots_\(wallet.stakePackShots)", shots: Int(wallet.stakePackShots),
                price: Int(clamping: wallet.stakePackPrice)
            )]
        }
        return WalletServerState(
            likes: Int(clamping: wallet.points),
            claimAvailable: wallet.claimAvailable,
            nextClaimAt: wallet.hasNextClaimAt ? wallet.nextClaimAt.date : nil,
            claimAmount: Int(wallet.claimAmount),
            claimedToday: Int(wallet.claimedToday),
            dailyClaimCap: Int(wallet.dailyClaimCap),
            streakDays: Int(wallet.streakDays),
            likesCap: Int(clamping: wallet.pointsCap),
            gems: Int(clamping: wallet.gems),
            stakeShots: Int(wallet.stakeShots),
            stakePackID: wallet.stakePackID.isEmpty ? nil : wallet.stakePackID,
            stakePacks: packs,
            gemSpendingRestricted: wallet.gemSpendingRestricted
        )
    }

    // MARK: - Spending gems (#1475)

    public func buyStakePack(packID: String, idempotencyKey: String) async throws
        -> (outcome: WalletStakePackPurchase, wallet: WalletServerState) {
        var request = Wallet_V1_BuyStakePackRequest()
        request.accountID = try await account()
        request.idempotencyKey = idempotencyKey
        request.packID = packID
        let response = await walletClient.buyStakePack(request: request, headers: [:])
        if let error = response.error {
            // Adults only (WAL-3001): a refusal, not a failure to ask.
            if error.code == .permissionDenied { return (.unavailable, try await wallet()) }
            throw NetworkFailureError(NetworkFailure(error))
        }
        guard let answer = response.message else { throw NetworkFailureError(.server(code: "empty_response")) }
        let state = Self.state(answer.wallet)
        let price = state.stakePacks.first { $0.id == packID }?.price ?? 0
        let outcome: WalletStakePackPurchase = switch answer.outcome {
        case .bought: .bought(shots: state.stakeShots, remainingGems: state.gems)
        case .packStillActive: .packStillActive(shotsLeft: state.stakeShots)
        case .insufficientGems: .insufficientGems(needed: price, have: state.gems)
        case .unspecified, .UNRECOGNIZED: .unavailable
        }
        return (outcome, state)
    }

    public func purchaseItem(itemID: String, expectedPrice: Int, idempotencyKey: String) async throws
        -> (outcome: WalletItemPurchase, wallet: WalletServerState) {
        var request = Wallet_V1_PurchaseItemRequest()
        request.accountID = try await account()
        request.idempotencyKey = idempotencyKey
        request.itemID = itemID
        request.expectedPrice = Int64(expectedPrice)
        let response = await walletClient.purchaseItem(request: request, headers: [:])
        if let error = response.error {
            if error.code == .permissionDenied { return (.unavailable, try await wallet()) }
            throw NetworkFailureError(NetworkFailure(error))
        }
        guard let answer = response.message else { throw NetworkFailureError(.server(code: "empty_response")) }
        let state = Self.state(answer.wallet)
        let outcome: WalletItemPurchase = switch answer.outcome {
        case .purchased: .purchased(remainingGems: state.gems)
        case .alreadyOwned: .alreadyOwned
        case .insufficientGems: .insufficientGems(needed: expectedPrice, have: state.gems)
        case .priceChanged: .priceChanged(price: nil)
        case .unknownItem, .unspecified, .UNRECOGNIZED: .unavailable
        }
        return (outcome, state)
    }

    public func ownedItems() async throws -> [String] {
        var request = Wallet_V1_ListOwnedItemsRequest()
        request.accountID = try await account()
        let response = await walletClient.listOwnedItems(request: request, headers: [:])
        if let error = response.error { throw NetworkFailureError(NetworkFailure(error)) }
        return (response.message?.items ?? []).map(\.itemID)
    }

    public func catalog() async throws -> [WalletCatalogItem] {
        let response = await walletClient.listCatalog(request: Wallet_V1_ListCatalogRequest(), headers: [:])
        if let error = response.error { throw NetworkFailureError(NetworkFailure(error)) }
        return (response.message?.items ?? []).map { WalletCatalogItem(id: $0.itemID, price: Int(clamping: $0.price)) }
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
