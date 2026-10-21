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
        let service = MockWalletService(store: MockCounterStore(dataset: dataset), dataset: dataset, startingLikes: 250)
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
        #expect(service.likes(of: MockAuthService.accountID) == 275)
    }

    /// ⚠️ A TEEN'S GEM SPEND IS REFUSED WITH NOTHING DEBITED (#1475, #1495):
    /// the store, over the edge to a wallet that answers WAL-3001, reports
    /// the refusal and keeps the gems, the shots and the items as they were.
    @Test func aTeensGemSpendIsRefusedWithNothingDebited() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let service = MockWalletService(
            store: MockCounterStore(dataset: dataset), dataset: dataset, startingLikes: 250,
            isGemSpendingRestricted: { _ in true }
        )
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
        #expect(store.gemSpendingRestricted, "the wallet did not say spending is restricted")
        await store.refreshItemsFromServer()
        let gems = store.snapshot().gems
        #expect(gems > 0, "the premise: gems to spend")

        let item = await store.purchaseItem("theme.violet", price: 50, idempotencyKey: "teen-item-0001")
        #expect(item == .unavailable, "the refusal was not the outcome: \(item)")
        #expect(store.snapshot().gems == gems, "gems were debited")
        #expect(store.ownedItems?.contains("theme.violet") != true, "the refused item is owned")

        let tier = try #require(store.stakePackTiers.first)
        let pack = await store.buyStakePack(tier, idempotencyKey: "teen-pack-0001")
        #expect(pack == .unavailable, "the refusal was not the outcome: \(pack)")
        #expect(store.snapshot().gems == gems, "gems were debited")
        #expect(store.stakeShots == 0, "shots were loaded")
        #expect(service.gems(of: MockAuthService.accountID) == Int64(gems), "the server charged")
    }

    /// A settled stake is the server's verdict alone: no gems in shadow
    /// mode (#903); a comment stake is left out of the post list.
    @Test func aSettledStakeIsItsVerdictAlone() {
        var settled = Wallet_V1_MyStake()
        settled.postID = "post-1"
        settled.points = 7
        settled.firstAt = .init(date: Date(timeIntervalSince1970: 1_000))
        settled.settlesAt = .init(date: Date(timeIntervalSince1970: 87_400))
        settled.settledAt = .init(date: Date(timeIntervalSince1970: 87_400))
        settled.verdict = .rewarded
        let stake = ServerWallet.stake(settled)
        #expect(stake?.outcome == .rewarded)
        #expect(stake?.gems == 0)
        #expect(stake?.amount == 7)

        var active = settled
        active.clearSettledAt()
        active.verdict = .unspecified
        #expect(ServerWallet.stake(active)?.outcome == nil)

        var comment = Wallet_V1_MyStake()
        comment.commentID = "c-1"
        #expect(ServerWallet.stake(comment) == nil)
    }

    /// A history row as the app keeps it (#400); a kind this build does not
    /// know is kept, as "other".
    @Test func aTransactionKeepsItsKindAmountAndBalance() {
        var wire = Wallet_V1_WalletTransaction()
        wire.transactionID = "tx-9"
        wire.currency = .gems
        wire.delta = -50
        wire.balanceAfter = 130
        wire.kind = .countryUnlock
        wire.refID = "FR"
        let row = ServerWallet.transaction(wire)
        #expect(row == WalletTransaction(
            id: "tx-9", currency: .gems, delta: -50, balanceAfter: 130, kind: .countryUnlock, createdAt: nil, reference: "FR"
        ))
        wire.kind = .UNRECOGNIZED(42)
        #expect(ServerWallet.transaction(wire).kind == .other)
    }

    /// The catalogue's purchases (#892) keep their own kind, not "other".
    @Test(arguments: [
        (Wallet_V1_TransactionKind.appIcon, WalletTransaction.Kind.appIcon),
        (.theme, .theme), (.countryVisa, .countryVisa), (.profileSlot, .profileSlot),
        (.handleChange, .handleChange), (.avatarFrame, .avatarFrame),
        (.animatedBanner, .animatedBanner), (.cardStyle, .cardStyle), (.animatedAvatar, .animatedAvatar),
    ])
    func aCataloguePurchaseKeepsItsKind(_ wire: Wallet_V1_TransactionKind, _ kind: WalletTransaction.Kind) {
        var transaction = Wallet_V1_WalletTransaction()
        transaction.kind = wire
        #expect(ServerWallet.transaction(transaction).kind == kind)
    }
}
