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
    var listed: [WalletStake] = []
    func setListed(_ stakes: [WalletStake]) { listed = stakes }
    func myStakes() async throws -> [WalletStake] {
        if fails { throw URLError(.notConnectedToInternet) }
        return listed
    }

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

/// ⚠️ The last wallet kept before the rename (#1397) is read back whole:
/// its keys are still "points" and "pointsCap".
@Test func aServerWalletKeptBeforeTheRenameIsReadBack() throws {
    let kept = """
    {"points":120,"claimAvailable":true,"claimAmount":25,"claimedToday":50,"dailyClaimCap":200,\
    "streakDays":3,"pointsCap":2000}
    """
    let state = try JSONDecoder().decode(WalletServerState.self, from: Data(kept.utf8))
    #expect(state.likes == 120)
    #expect(state.likesCap == 2_000)
    let written = try #require(String(data: JSONEncoder().encode(state), encoding: .utf8))
    #expect(written.contains("\"points\":120") && written.contains("\"pointsCap\":2000"), "the stored keys changed")
}

private func serverState(likes: Int, available: Bool = true, next: Date? = nil, amount: Int = 25) -> WalletServerState {
    WalletServerState(
        likes: likes, claimAvailable: available, nextClaimAt: next, claimAmount: amount,
        claimedToday: 50, dailyClaimCap: 200, streakDays: 3, likesCap: 2_000
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
        let fixture = Fixture(serverState(likes: 640, available: false, next: next))

        #expect(await fixture.store.refreshFromServer())

        let snapshot = fixture.store.snapshot()
        #expect(snapshot.balance == 640)
        #expect(!snapshot.claimAvailable)
        #expect(snapshot.nextClaimAt == next)
        #expect(snapshot.streakDays == 3)
        #expect(snapshot.claimedToday == 50)
        #expect(snapshot.likesCap == 2_000)
    }

    /// Likes this device took off but has not sent are not in the server's
    /// points yet: they stay off.
    @Test func likesNotSentYetStayOffTheServersPoints() async {
        let fixture = Fixture(serverState(likes: 300))
        let outbox = LikeOutbox(defaults: fixture.defaults, scope: fixture.scope)
        fixture.store.likeOutbox = outbox
        await fixture.store.refreshFromServer()

        fixture.store.stake(.likes(4), on: "post-1")
        #expect(fixture.store.balance == 296)

        await fixture.store.refreshFromServer()
        #expect(fixture.store.balance == 296)
    }

    /// A claim goes to the server with the tap's key, and its answer — the
    /// outcome and the wallet — is applied.
    @Test func aClaimIsTheServersAnswer() async {
        let fixture = Fixture(serverState(likes: 100))
        await fixture.store.refreshFromServer()
        await fixture.server.setClaimAnswer(.claimed(awarded: 30), then: serverState(likes: 130, available: false, next: Date().addingTimeInterval(3_600)))

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
        let fixture = Fixture(serverState(likes: 100))
        await fixture.server.setClaimAnswer(.balanceFull, then: serverState(likes: 2_000, available: false, next: nil, amount: 0))

        #expect(await fixture.store.claim(idempotencyKey: "tapkey-0002") == .balanceFull)
        #expect(fixture.store.snapshot().nextClaimAt == nil)
        #expect(fixture.store.snapshot().claimCountdown == nil)
    }

    /// Offline: nothing changes, and the outcome says the server was not
    /// reached.
    @Test func anUnreachableServerChangesNothing() async {
        let fixture = Fixture(serverState(likes: 100))
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
        let server = FakeWalletServer(serverState(likes: 999))
        store.server = server

        #expect(!(await store.refreshFromServer()))
        _ = await store.claim(idempotencyKey: "tapkey-0004")
        #expect(await server.reads == 0)
        #expect(await server.claimKeys.isEmpty)
    }

    /// A wallet read as one account never lands in another's.
    @Test func aReadNeverLandsInAnotherAccount() {
        let fixture = Fixture(serverState(likes: 100))
        let applied = fixture.store.apply(serverState(likes: 777), readAs: .member(account: "acct-2", profile: nil))
        #expect(!applied)
        #expect(fixture.store.balance != 777)
    }

    /// With the wallet the server's, the welcome gift is the server's to
    /// credit (#1008): settling it credits nothing on the device.
    @Test func theWelcomeGiftIsNotCreditedOnTheDevice() async {
        let fixture = Fixture(serverState(likes: 100))
        await fixture.store.refreshFromServer()
        let gift = WelcomeGift(defaults: fixture.defaults)
        gift.open()

        let amount = gift.settle(into: fixture.store)

        #expect(amount > 0)
        #expect(fixture.store.balance == 100)
    }

    /// The sheet's stakes are the server's list (#903), with the device's
    /// taps the server has not been sent yet as active ones on top.
    @Test func theStakesAreTheServersListWithTheUnsentOnTop() async {
        let fixture = Fixture(serverState(likes: 300))
        let outbox = LikeOutbox(defaults: fixture.defaults, scope: fixture.scope)
        fixture.store.likeOutbox = outbox
        await fixture.store.refreshFromServer()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        await fixture.server.setListed([
            WalletStake(targetID: "post-old", amount: 9, stakedAt: day, settlesAt: day.addingTimeInterval(86_400), outcome: .rewarded),
        ])
        #expect(await fixture.store.refreshStakesFromServer())

        fixture.store.stake(.likes(2), on: "post-new")

        let stakes = fixture.store.stakes()
        #expect(stakes.map(\.targetID) == ["post-new", "post-old"])
        #expect(stakes.last?.outcome == .rewarded)
        #expect(stakes.first?.isSettled == false)
    }

    /// Until the server lists the stakes, a settled one's outcome is the
    /// device's guess (#1395): the sheet waits for the verdicts. Listed,
    /// nothing is awaited any more.
    @Test func theVerdictsAreAwaitedUntilTheServerListsTheStakes() async {
        let fixture = Fixture(serverState(likes: 300))
        #expect(fixture.store.awaitsServerStakes, "a member with a server waits for its listing")
        #expect(await fixture.store.refreshStakesFromServer())
        #expect(!fixture.store.awaitsServerStakes)
    }

    /// A listing that fails leaves the device's outcomes standing: the sheet
    /// draws them rather than bones that never resolve.
    @Test func aFailedListingAwaitsNothing() async {
        let fixture = Fixture(serverState(likes: 300))
        await fixture.server.setFails(true)
        #expect(await !fixture.store.refreshStakesFromServer())
        #expect(!fixture.store.awaitsServerStakes)
        // And a later listing that answers is the truth again.
        await fixture.server.setFails(false)
        #expect(await fixture.store.refreshStakesFromServer())
        #expect(!fixture.store.awaitsServerStakes)
    }

    /// No server, or a guest: there is no listing to wait for.
    @Test func withoutAServerOrForAGuestNothingIsAwaited() {
        let defaults = UserDefaults(suiteName: "wallet-server-\(UUID().uuidString)")!
        let member = WalletStore(defaults: defaults, scope: StorageScope(owner: .member(account: "a", profile: nil)))
        #expect(!member.awaitsServerStakes)
        let guest = WalletStore(defaults: defaults, scope: StorageScope(owner: .guest))
        guest.server = FakeWalletServer(serverState(likes: 1))
        #expect(!guest.awaitsServerStakes)
    }

    /// A guest has no wallet history to read (#400).
    @Test func aGuestHasNoHistory() async {
        let defaults = UserDefaults(suiteName: "wallet-server-\(UUID().uuidString)")!
        let store = WalletStore(defaults: defaults, scope: StorageScope(owner: .guest))
        store.server = FakeWalletServer(serverState(likes: 1))
        await #expect(throws: WalletHistoryUnavailable.self) {
            _ = try await store.transactions(currency: nil, after: nil)
        }
    }
}
