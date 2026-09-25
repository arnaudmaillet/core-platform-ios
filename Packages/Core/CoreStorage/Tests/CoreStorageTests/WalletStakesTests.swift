import Foundation
import Testing
@testable import CoreStorage

/// Stakes (currency A committed to a post) and their deferred settlement into
/// gems (currency B) — charter V5.3 §33.
struct WalletStakesTests {
    private static let epoch = Date(timeIntervalSince1970: 1_755_000_000)

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ now: Date) { _now = now }
        var now: Date {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
        func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
    }

    private static func defaults() -> UserDefaults {
        let name = "wallet-stakes-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static let delay = WalletStore.Policy.settlementDelay

    @Test func aStakeIsActiveUntilItSettles() {
        let clock = Clock(Self.epoch)
        let store = WalletStore(defaults: Self.defaults(), now: { clock.now })
        store.boost(targetID: "post-1", amount: 10)

        let active = store.stakes()
        #expect(active.count == 1)
        #expect(active.first?.isSettled == false, "settled at once — the charter defers it")
        #expect(active.first?.settlesAt == Self.epoch.addingTimeInterval(Self.delay))
        #expect(store.snapshot().gems == 0)

        clock.advance(by: Self.delay)
        let settled = store.stakes()
        #expect(settled.first?.isSettled == true)
        #expect(settled.first?.outcome == WalletStore.Policy.mockOutcome(targetID: "post-1", amount: 10))
        #expect(store.snapshot().gems == settled.first?.gems)
    }

    /// Adding to a stake does not restart its clock.
    @Test func moreOnTheSamePostKeepsTheFirstStakesClock() {
        let clock = Clock(Self.epoch)
        let store = WalletStore(defaults: Self.defaults(), now: { clock.now })
        store.boost(targetID: "post-1", amount: 10)
        clock.advance(by: 3600)
        store.boost(targetID: "post-1", amount: 10)

        let stake = store.stakes().first
        #expect(stake?.amount == 20)
        #expect(stake?.stakedAt == Self.epoch)
    }

    @Test func activeStakesComeFirstSoonestFirstThenSettledNewestFirst() {
        let clock = Clock(Self.epoch)
        let store = WalletStore(defaults: Self.defaults(), now: { clock.now })
        store.boost(targetID: "old", amount: 10)
        clock.advance(by: 3600)
        store.boost(targetID: "older-settled-first", amount: 10)
        clock.advance(by: Self.delay)            // both of those have settled
        store.boost(targetID: "active-late", amount: 10)
        clock.advance(by: 60)
        store.boost(targetID: "active-later", amount: 10)

        #expect(store.stakes().map(\.targetID) == ["active-late", "active-later", "older-settled-first", "old"])
    }

    @Test func anUndoneStakeLeavesNothingToSettle() {
        let store = WalletStore(defaults: Self.defaults(), now: { Self.epoch })
        store.boost(targetID: "post-1", amount: 10)
        _ = store.undoBoost(targetID: "post-1", amount: 10)
        #expect(store.stakes().isEmpty)
    }

    /// The same stake always settles the same way — the outcome is not a
    /// dice roll per reading or per launch.
    @Test func theMockOutcomeIsStable() {
        let first = WalletStore.Policy.mockOutcome(targetID: "post-0042", amount: 40)
        #expect(WalletStore.Policy.mockOutcome(targetID: "post-0042", amount: 40) == first)
        if case .gems(let earned) = first { #expect(earned >= 1 && earned < 40) }
    }

    /// Across many posts some stakes earn and some do not — "No reward" is a
    /// normal settlement, not an edge case.
    @Test func someStakesEarnAndSomeDoNot() {
        let outcomes = (0..<200).map { WalletStore.Policy.mockOutcome(targetID: "post-\($0)", amount: 20) }
        let earned = outcomes.filter { if case .gems = $0 { return true } else { return false } }.count
        #expect(earned > 60 && earned < 160, "\(earned) of 200 earned")
    }

    @Test func theDemoLedgerSeedsOnceWithActiveAndSettledStakes() {
        let defaults = Self.defaults()
        let store = WalletStore(defaults: defaults, now: { Self.epoch })
        let balance = store.balance
        let ids = (0..<8).map { "post-\($0)" }
        store.seedDemoStakesIfNeeded(targetIDs: ids)

        let stakes = store.stakes()
        #expect(stakes.count == 8)
        #expect(stakes.contains { !$0.isSettled } && stakes.contains(where: \.isSettled))
        #expect(store.balance == balance, "seeding spent the viewer's points")

        store.seedDemoStakesIfNeeded(targetIDs: ["post-99"])
        #expect(store.stakes().count == 8, "the demo ledger seeded twice")
    }

    /// Boosts recorded before stakes had dates are dated once, as settled.
    @Test func undatedBoostsBecomeSettledStakes() {
        let defaults = Self.defaults()
        defaults.set(true, forKey: "wallet.seeded")
        defaults.set(["legacy": 30], forKey: "wallet.boostTotals")
        let store = WalletStore(defaults: defaults, now: { Self.epoch })
        #expect(store.stakes().first?.isSettled == true)
    }
}
