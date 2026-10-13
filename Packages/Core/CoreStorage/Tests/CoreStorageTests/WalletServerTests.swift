import Foundation
import Testing
@testable import CoreStorage

// A member's wallet is the server's (#1098).

private actor FakeWalletServer: WalletServer {
    var state: WalletServerState
    var claimAnswer: WalletClaimOutcome = .claimed(awarded: 25)
    var fails = false
    private(set) var reads = 0
    private(set) var claimKeys: [String] = []

    init(_ state: WalletServerState) { self.state = state }

    func setFails(_ fails: Bool) { self.fails = fails }
    func setClaimAnswer(_ outcome: WalletClaimOutcome, then next: WalletServerState) {
        claimAnswer = outcome
        state = next
    }

    func wallet() async throws -> WalletServerState {
        reads += 1
        if fails { throw URLError(.notConnectedToInternet) }
        return state
    }

    func claim(idempotencyKey: String) async throws -> (outcome: WalletClaimOutcome, wallet: WalletServerState) {
        claimKeys.append(idempotencyKey)
        if fails { throw URLError(.notConnectedToInternet) }
        return (claimAnswer, state)
    }
}

private func serverState(points: Int, available: Bool = true, next: Date? = nil, amount: Int = 25) -> WalletServerState {
    WalletServerState(
        points: points, claimAvailable: available, nextClaimAt: next, claimAmount: amount,
        claimedToday: 50, dailyClaimCap: 200, streakDays: 3, pointsCap: 2_000
    )
}

private struct Fixture {
    let defaults = UserDefaults(suiteName: "wallet-server-\(UUID().uuidString)")!
    let scope = StorageScope(owner: .member(account: "acct-1", profile: "prof-1"))
    let store: WalletStore
    let server: FakeWalletServer

    init(_ state: WalletServerState) {
        store = WalletStore(defaults: defaults, scope: scope)
        server = FakeWalletServer(state)
        store.server = server
    }
}

struct WalletServerTests {
    /// The balance, the claim and its clock are the server's once read.
    @Test func theServersWalletIsWhatTheStoreShows() async {
        let next = Date().addingTimeInterval(1_200)
        let fixture = Fixture(serverState(points: 640, available: false, next: next))

        #expect(await fixture.store.refreshFromServer())

        let snapshot = fixture.store.snapshot()
        #expect(snapshot.balance == 640)
        #expect(!snapshot.claimAvailable)
        #expect(snapshot.nextClaimAt == next)
        #expect(snapshot.streakDays == 3)
        #expect(snapshot.claimedToday == 50)
        #expect(snapshot.pointsCap == 2_000)
    }

    /// Likes this device took off but has not sent are not in the server's
    /// points yet: they stay off.
    @Test func likesNotSentYetStayOffTheServersPoints() async {
        let fixture = Fixture(serverState(points: 300))
        let outbox = LikeOutbox(defaults: fixture.defaults, scope: fixture.scope)
        fixture.store.likeOutbox = outbox
        await fixture.store.refreshFromServer()

        fixture.store.stake(.points(4), on: "post-1")
        #expect(fixture.store.balance == 296)

        await fixture.store.refreshFromServer()
        #expect(fixture.store.balance == 296)
    }

    /// A claim goes to the server with the tap's key, and its answer — the
    /// outcome and the wallet — is applied.
    @Test func aClaimIsTheServersAnswer() async {
        let fixture = Fixture(serverState(points: 100))
        await fixture.store.refreshFromServer()
        await fixture.server.setClaimAnswer(.claimed(awarded: 30), then: serverState(points: 130, available: false, next: Date().addingTimeInterval(3_600)))

        let outcome = await fixture.store.claim(idempotencyKey: "tapkey-0001")

        #expect(outcome == .claimed(awarded: 30))
        #expect(await fixture.server.claimKeys == ["tapkey-0001"])
        // The answer carries the wallet: no read after it.
        #expect(await fixture.server.reads == 1)
        #expect(fixture.store.balance == 130)
        #expect(!fixture.store.snapshot().claimAvailable)
    }

    /// At the points cap: the outcome says so, and there is no countdown.
    @Test func aFullWalletHasNoCountdown() async {
        let fixture = Fixture(serverState(points: 100))
        await fixture.server.setClaimAnswer(.balanceFull, then: serverState(points: 2_000, available: false, next: nil, amount: 0))

        #expect(await fixture.store.claim(idempotencyKey: "tapkey-0002") == .balanceFull)
        #expect(fixture.store.snapshot().nextClaimAt == nil)
        #expect(fixture.store.snapshot().claimCountdown == nil)
    }

    /// Offline: nothing changes, and the outcome says the server was not
    /// reached.
    @Test func anUnreachableServerChangesNothing() async {
        let fixture = Fixture(serverState(points: 100))
        await fixture.store.refreshFromServer()
        await fixture.server.setFails(true)

        #expect(await fixture.store.claim(idempotencyKey: "tapkey-0003") == .unavailable)
        #expect(!(await fixture.store.refreshFromServer()))
        #expect(fixture.store.balance == 100)
    }

    /// A guest never asks the server.
    @Test func aGuestNeverAsks() async {
        let defaults = UserDefaults(suiteName: "wallet-server-\(UUID().uuidString)")!
        let store = WalletStore(defaults: defaults, scope: StorageScope(owner: .guest))
        let server = FakeWalletServer(serverState(points: 999))
        store.server = server

        #expect(!(await store.refreshFromServer()))
        _ = await store.claim(idempotencyKey: "tapkey-0004")
        #expect(await server.reads == 0)
        #expect(await server.claimKeys.isEmpty)
    }

    /// A wallet read as one account never lands in another's.
    @Test func aReadNeverLandsInAnotherAccount() {
        let fixture = Fixture(serverState(points: 100))
        let applied = fixture.store.apply(serverState(points: 777), readAs: .member(account: "acct-2", profile: nil))
        #expect(!applied)
        #expect(fixture.store.balance != 777)
    }

    /// With the wallet the server's, the welcome gift is the server's to
    /// credit (#1008): settling it credits nothing on the device.
    @Test func theWelcomeGiftIsNotCreditedOnTheDevice() async {
        let fixture = Fixture(serverState(points: 100))
        await fixture.store.refreshFromServer()
        let gift = WelcomeGift(defaults: fixture.defaults)
        gift.open()

        let amount = gift.settle(into: fixture.store)

        #expect(amount > 0)
        #expect(fixture.store.balance == 100)
    }
}
