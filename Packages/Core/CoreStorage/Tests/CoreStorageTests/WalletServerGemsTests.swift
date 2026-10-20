import Foundation
import Testing
@testable import CoreStorage

/// A server that sells (#1475): its gems, its packs, its catalogue.
private actor SellingServer: WalletServer {
    var state: WalletServerState
    var owned: [String] = ["theme.pink"]
    var prices: [String: Int] = ["theme.violet": 50, "banner.animated": 500]
    var fails = false
    private(set) var itemKeys: [String] = []

    init(_ state: WalletServerState) { self.state = state }

    func setFails(_ fails: Bool) { self.fails = fails }
    func setPrice(_ price: Int, of item: String) { prices[item] = price }

    func wallet() async throws -> WalletServerState {
        if fails { throw URLError(.notConnectedToInternet) }
        return state
    }

    func claim(idempotencyKey: String) async throws -> (outcome: WalletClaimOutcome, wallet: WalletServerState) {
        (.dailyCapReached, state)
    }

    func buyStakePack(packID: String, idempotencyKey: String) async throws
        -> (outcome: WalletStakePackPurchase, wallet: WalletServerState) {
        if fails { throw URLError(.notConnectedToInternet) }
        guard state.stakeShots == 0 else { return (.packStillActive(shotsLeft: state.stakeShots), state) }
        let pack = state.stakePacks.first { $0.id == packID } ?? state.stakePacks[0]
        guard state.gems >= pack.price else { return (.insufficientGems(needed: pack.price, have: state.gems), state) }
        state.gems -= pack.price
        state.stakeShots = pack.shots
        state.stakePackID = pack.id
        return (.bought(shots: pack.shots, remainingGems: state.gems), state)
    }

    func purchaseItem(itemID: String, expectedPrice: Int, idempotencyKey: String) async throws
        -> (outcome: WalletItemPurchase, wallet: WalletServerState) {
        if fails { throw URLError(.notConnectedToInternet) }
        itemKeys.append(idempotencyKey)
        guard let price = prices[itemID] else { return (.unavailable, state) }
        guard !owned.contains(itemID) else { return (.alreadyOwned, state) }
        guard price == expectedPrice else { return (.priceChanged(price: nil), state) }
        guard state.gems >= price else { return (.insufficientGems(needed: price, have: state.gems), state) }
        state.gems -= price
        owned.append(itemID)
        return (.purchased(remainingGems: state.gems), state)
    }

    func ownedItems() async throws -> [String] {
        if fails { throw URLError(.notConnectedToInternet) }
        return owned
    }

    func catalog() async throws -> [WalletCatalogItem] {
        if fails { throw URLError(.notConnectedToInternet) }
        return prices.map { WalletCatalogItem(id: $0.key, price: $0.value) }
    }
}

private func state(gems: Int, shots: Int = 0) -> WalletServerState {
    WalletServerState(
        likes: 300, claimAvailable: true, nextClaimAt: nil, claimAmount: 25,
        claimedToday: 0, dailyClaimCap: 200, streakDays: 1, likesCap: 2_000,
        gems: gems, stakeShots: shots, stakePackID: shots > 0 ? "shots_3" : nil,
        stakePacks: [
            .init(id: "shots_3", shots: 3, price: 50), .init(id: "shots_10", shots: 10, price: 150),
        ]
    )
}

private struct Fixture {
    let defaults = UserDefaults(suiteName: "wallet-gems-\(UUID().uuidString)")!
    let scope = StorageScope(owner: .member(account: "acct-1", profile: "prof-1"))
    let store: WalletStore
    let server: SellingServer

    init(_ state: WalletServerState) {
        store = WalletStore(defaults: defaults, scope: scope)
        server = SellingServer(state)
        store.server = server
    }
}

struct WalletServerGemsTests {
    /// A member's gems are the server's once read, whatever the device kept;
    /// its packs on sale and its shots too.
    @Test func theGemsAreTheServers() async {
        let fixture = Fixture(state(gems: 137, shots: 2))
        #expect(fixture.store.isServerBacked)
        #expect(await fixture.store.refreshFromServer())
        let snapshot = fixture.store.snapshot()
        #expect(snapshot.gems == 137)
        #expect(snapshot.stakeShots == 2)
        #expect(fixture.store.stakePackTiers.map(\.id) == ["shots_3", "shots_10"])
        #expect(fixture.store.stakePackTierID == "shots_3")
    }

    /// A wallet stored by a build before the gems still reads, with none.
    @Test func aWalletStoredBeforeTheGemsStillReads() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state(gems: 40, shots: 1))) as? [String: Any])
        for key in ["gems", "stakeShots", "stakePackID", "stakePacks", "gemSpendingRestricted"] {
            json.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(WalletServerState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.likes == 300)
        #expect(decoded.gems == 0)
        #expect(decoded.stakePacks.isEmpty)
        #expect(!decoded.gemSpendingRestricted)
    }

    /// A pack bought through the server: its answer is the wallet.
    @Test func aPackIsBoughtThroughTheServer() async {
        let fixture = Fixture(state(gems: 120))
        await fixture.store.refreshFromServer()
        let tier = WalletStore.Policy.StakePack.Tier(id: "shots_3", shots: 3, price: 50)
        #expect(await fixture.store.buyStakePack(tier, idempotencyKey: "key-00001") == .bought(shots: 3, remainingGems: 70))
        #expect(fixture.store.snapshot().gems == 70)
        #expect(fixture.store.snapshot().stakeShots == 3)
        #expect(await fixture.store.buyStakePack(tier, idempotencyKey: "key-00002") == .packStillActive(shotsLeft: 3))
        await fixture.server.setFails(true)
        let big = WalletStore.Policy.StakePack.Tier(id: "shots_10", shots: 10, price: 150)
        #expect(await fixture.store.buyStakePack(big, idempotencyKey: "key-00003") == .unavailable)
    }

    /// An item bought through the server is owned at once, and its gems go;
    /// a price that moved answers the new one, nothing charged.
    @Test func anItemIsBoughtThroughTheServerAndOwned() async {
        let fixture = Fixture(state(gems: 120))
        await fixture.store.refreshFromServer()
        #expect(await fixture.store.refreshItemsFromServer())
        #expect(fixture.store.ownedItems == ["theme.pink"])
        #expect(fixture.store.catalogPrice(of: "theme.violet") == 50)

        #expect(await fixture.store.purchaseItem("theme.violet", price: 50, idempotencyKey: "key-00001")
            == .purchased(remainingGems: 70))
        #expect(fixture.store.ownedItems == ["theme.pink", "theme.violet"])
        #expect(fixture.store.snapshot().gems == 70)

        await fixture.server.setPrice(60, of: "banner.animated")
        #expect(await fixture.store.purchaseItem("banner.animated", price: 500, idempotencyKey: "key-00002")
            == .priceChanged(price: 60))
        #expect(fixture.store.snapshot().gems == 70, "nothing charged")

        await fixture.server.setFails(true)
        #expect(await fixture.store.purchaseItem("banner.animated", price: 60, idempotencyKey: "key-00003") == .failed)
    }

    /// A spend no server call carries yet (the mock's country unlocks) comes
    /// off the server's balance on this device; never below it.
    @Test func aSpendOffTheServerComesOffItsBalance() async {
        let fixture = Fixture(state(gems: 40))
        await fixture.store.refreshFromServer()
        #expect(fixture.store.spendGems(15) == .spent(remaining: 25))
        #expect(fixture.store.snapshot().gems == 25)
        #expect(fixture.store.spendGems(30) == .insufficient(gems: 25))
    }

    /// A guest's wallet is not the server's: nothing goes through it.
    @Test func aGuestsWalletIsNotTheServers() async {
        let defaults = UserDefaults(suiteName: "wallet-gems-\(UUID().uuidString)")!
        let guest = WalletStore(defaults: defaults, scope: StorageScope(owner: .guest))
        guest.server = SellingServer(state(gems: 999))
        #expect(!guest.isServerBacked)
        #expect(await guest.purchaseItem("theme.violet", price: 50, idempotencyKey: "key-00001") == .unavailable)
        #expect(guest.ownedItems == nil)
    }
}
