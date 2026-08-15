import Foundation
import Testing
@testable import CoreStorage

/// Each test gets its own suite-named `UserDefaults` so nothing leaks between
/// them or into the running app's real defaults — the swift-testing runner is
/// parallel, and a shared suite would let one test's writes race another's.
private func makeDefaults() -> UserDefaults {
    let name = "wallet-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// A wallet on a controllable clock. `epoch` is an arbitrary fixed instant;
/// tests move time by mutating the box, never by sleeping.
private let epoch = Date(timeIntervalSince1970: 1_755_000_000) // 2025-08-12T12:00:00Z

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

private func makeStore(
    defaults: UserDefaults = makeDefaults(),
    clock: Clock = Clock(epoch)
) -> WalletStore {
    WalletStore(defaults: defaults, now: { clock.now })
}

struct WalletStoreTests {

    // MARK: - Seeding & persistence

    @Test func aFreshWalletCarriesTheSeededBalance() {
        let store = makeStore()
        #expect(store.balance == WalletStore.Policy.seededBalance)
    }

    @Test func theSeedLandsOnceNotOnEveryLaunch() {
        let defaults = makeDefaults()
        let clock = Clock(epoch)
        let first = makeStore(defaults: defaults, clock: clock)
        first.claim()
        let balanceAfterClaim = first.balance

        // A second store over the same defaults is a relaunch.
        let second = makeStore(defaults: defaults, clock: clock)
        #expect(second.balance == balanceAfterClaim)
    }

    @Test func stateSurvivesRelaunch() {
        let defaults = makeDefaults()
        let clock = Clock(epoch)
        let first = makeStore(defaults: defaults, clock: clock)
        first.claim()
        first.boost(targetID: "post-1", amount: 10)

        let second = makeStore(defaults: defaults, clock: clock)
        #expect(second.balance == first.balance)
        #expect(second.boostTotal(forTarget: "post-1") == 10)
        #expect(second.snapshot().claimAvailable == false)
    }

    // MARK: - Claiming

    @Test func aFreshWalletCanClaimImmediately() {
        let store = makeStore()
        let snapshot = store.snapshot()
        #expect(snapshot.claimAvailable)
        #expect(snapshot.nextClaimAt == nil)
        #expect(snapshot.claimAmount == WalletStore.Policy.baseClaimAmount)
    }

    @Test func claimingCreditsTheBaseAmount() {
        let store = makeStore()
        let outcome = store.claim()
        #expect(outcome == .claimed(awarded: WalletStore.Policy.baseClaimAmount))
        #expect(store.balance == WalletStore.Policy.seededBalance + WalletStore.Policy.baseClaimAmount)
    }

    @Test func aSecondClaimInsideTheIntervalIsTooEarly() {
        let clock = Clock(epoch)
        let store = makeStore(clock: clock)
        store.claim()
        clock.advance(by: WalletStore.Policy.claimInterval - 1)

        let outcome = store.claim()
        #expect(outcome == .tooEarly(nextClaimAt: epoch.addingTimeInterval(WalletStore.Policy.claimInterval)))

        let snapshot = store.snapshot()
        #expect(!snapshot.claimAvailable)
        #expect(snapshot.nextClaimAt == epoch.addingTimeInterval(WalletStore.Policy.claimInterval))
    }

    @Test func theClaimUnlocksWhenTheIntervalPasses() {
        let clock = Clock(epoch)
        let store = makeStore(clock: clock)
        store.claim()
        clock.advance(by: WalletStore.Policy.claimInterval)
        #expect(store.snapshot().claimAvailable)
        #expect(store.claim() == .claimed(awarded: WalletStore.Policy.baseClaimAmount))
    }

    @Test func theDailyCapStopsClaimsAndPointsAtUTCMidnight() {
        let clock = Clock(epoch)
        let store = makeStore(clock: clock)
        // 25/claim, 200/day: eight claims fill the cap.
        for _ in 0..<8 {
            #expect(store.snapshot().claimAvailable)
            store.claim()
            clock.advance(by: WalletStore.Policy.claimInterval)
        }
        #expect(store.claim() == .dailyCapReached)

        let snapshot = store.snapshot()
        #expect(snapshot.claimedToday == WalletStore.Policy.dailyClaimCap)
        #expect(!snapshot.claimAvailable)
        // The countdown targets the UTC day boundary, not lastClaim + 1h.
        // epoch is 12:00Z, eight hourly claims end at 20:00Z → midnight is 4h out.
        #expect(snapshot.nextClaimAt == clock.now.addingTimeInterval(4 * 60 * 60))
    }

    @Test func theLastClaimOfTheDayIsClippedToTheCap() {
        let clock = Clock(epoch)
        let store = makeStore(clock: clock)
        // Build a ×1.8 multiplier: one claim a day for eight days.
        for _ in 0..<8 {
            store.claim()
            clock.advance(by: 24 * 60 * 60)
        }
        // Day 9 (streak 9): claims pay 45. Four of them fill 180 of the cap…
        for _ in 0..<4 {
            #expect(store.claim() == .claimed(awarded: 45))
            clock.advance(by: WalletStore.Policy.claimInterval)
        }
        // …and the fifth is clipped to the remainder, not refused.
        #expect(store.snapshot().claimAmount == 20)
        #expect(store.claim() == .claimed(awarded: 20))
        #expect(store.claim() == .dailyCapReached)
    }

    @Test func theCapResetsOnTheNextUTCDay() {
        let clock = Clock(epoch)
        let store = makeStore(clock: clock)
        for _ in 0..<8 {
            store.claim()
            clock.advance(by: WalletStore.Policy.claimInterval)
        }
        #expect(store.claim() == .dailyCapReached)

        clock.advance(by: 24 * 60 * 60)
        let snapshot = store.snapshot()
        #expect(snapshot.claimAvailable)
        #expect(snapshot.claimedToday == 0)
    }

    // MARK: - Streaks

    @Test func claimingOnConsecutiveDaysGrowsTheStreakAndTheMultiplier() {
        let clock = Clock(epoch)
        let store = makeStore(clock: clock)
        #expect(store.claim() == .claimed(awarded: 25))
        #expect(store.snapshot().streakDays == 1)

        clock.advance(by: 24 * 60 * 60)
        // Day 2 pays ×1.1.
        #expect(store.claim() == .claimed(awarded: 28))
        #expect(store.snapshot().streakDays == 2)

        clock.advance(by: 24 * 60 * 60)
        // Day 3 pays ×1.2.
        #expect(store.claim() == .claimed(awarded: 30))
        #expect(store.snapshot().streakDays == 3)
    }

    @Test func theMultiplierIsCappedAtDouble() {
        #expect(WalletStore.Policy.multiplier(forStreak: 11) == 2.0)
        #expect(WalletStore.Policy.multiplier(forStreak: 100) == 2.0)
    }

    @Test func aMissedDayResetsTheStreak() {
        let clock = Clock(epoch)
        let store = makeStore(clock: clock)
        store.claim()
        clock.advance(by: 24 * 60 * 60)
        store.claim()
        #expect(store.snapshot().streakDays == 2)

        // Skip a full UTC day: the chain is broken.
        clock.advance(by: 2 * 24 * 60 * 60)
        #expect(store.snapshot().streakDays == 0)
        #expect(store.claim() == .claimed(awarded: 25))
        #expect(store.snapshot().streakDays == 1)
    }

    @Test func sameDayClaimsDoNotGrowTheStreak() {
        let clock = Clock(epoch)
        let store = makeStore(clock: clock)
        store.claim()
        clock.advance(by: WalletStore.Policy.claimInterval)
        store.claim()
        #expect(store.snapshot().streakDays == 1)
    }

    // MARK: - Boosting

    @Test func boostingDebitsAndAccumulatesPerTarget() {
        let store = makeStore()
        let first = store.boost(targetID: "post-1", amount: 10)
        #expect(first == .boosted(newBalance: WalletStore.Policy.seededBalance - 10, targetTotal: 10, spent: 10))

        let second = store.boost(targetID: "post-1", amount: 50)
        #expect(second == .boosted(newBalance: WalletStore.Policy.seededBalance - 60, targetTotal: 60, spent: 50))
        #expect(store.boostTotal(forTarget: "post-1") == 60)
        #expect(store.boostTotal(forTarget: "post-2") == 0)
    }

    @Test func anUnaffordableBoostChangesNothing() {
        let store = makeStore()
        // Drain the balance on another target first: an over-cap request on
        // a FRESH target clamps to the cap instead (see the cap tests), so
        // "can't afford it" needs a request under the cap but over the
        // remaining balance.
        store.boost(targetID: "post-a", amount: 200)
        let outcome = store.boost(targetID: "post-1", amount: 100)
        #expect(outcome == .insufficientBalance(balance: WalletStore.Policy.seededBalance - 200))
        #expect(store.balance == WalletStore.Policy.seededBalance - 200)
        #expect(store.boostTotal(forTarget: "post-1") == 0)
    }

    @Test func boostsClampToThePerTargetCapAndThenRefuse() {
        let store = makeStore() // seeded 250 = exactly one cap
        store.boost(targetID: "post-1", amount: 200)

        // 100 requested, 50 left under the cap: partial fill, real debit 50.
        let clamped = store.boost(targetID: "post-1", amount: 100)
        #expect(clamped == .boosted(
            newBalance: 0, targetTotal: WalletStore.Policy.perTargetBoostCap, spent: 50
        ))

        // Full target: refused outright, nothing changes, nothing posts.
        let counter = NotificationCounter(object: store)
        #expect(store.boost(targetID: "post-1", amount: 10)
            == .targetCapReached(targetTotal: WalletStore.Policy.perTargetBoostCap))
        #expect(counter.count == 0)
        #expect(store.boostTotal(forTarget: "post-1") == WalletStore.Policy.perTargetBoostCap)
    }

    @Test func undoBoostCreditsBackAndShrinksTheTarget() {
        let store = makeStore()
        store.boost(targetID: "post-1", amount: 50)

        let result = store.undoBoost(targetID: "post-1", amount: 30)
        #expect(result?.newBalance == WalletStore.Policy.seededBalance - 20)
        #expect(result?.targetTotal == 20)
        #expect(store.balance == WalletStore.Policy.seededBalance - 20)
        #expect(store.boostTotal(forTarget: "post-1") == 20)
    }

    @Test func undoBoostIsClampedToWhatTheTargetHolds() {
        let store = makeStore()
        store.boost(targetID: "post-1", amount: 10)

        // Asking for more than was spent refunds exactly the spend — a
        // stale caller can never mint points.
        let result = store.undoBoost(targetID: "post-1", amount: 1_000)
        #expect(result?.newBalance == WalletStore.Policy.seededBalance)
        #expect(result?.targetTotal == 0)
        #expect(store.boostTotal(forTarget: "post-1") == 0)
    }

    @Test func undoingAnUnboostedTargetChangesNothing() {
        let store = makeStore()
        let counter = NotificationCounter(object: store)
        #expect(store.undoBoost(targetID: "post-9", amount: 10) == nil)
        #expect(store.balance == WalletStore.Policy.seededBalance)
        #expect(counter.count == 0)
    }

    @Test func undoBoostPostsAChangeNotification() {
        let store = makeStore()
        store.boost(targetID: "post-1", amount: 10)
        let counter = NotificationCounter(object: store)
        store.undoBoost(targetID: "post-1", amount: 10)
        #expect(counter.count == 1)
    }

    @Test func boostsAndClaimsShareOneBalance() {
        let clock = Clock(epoch)
        let store = makeStore(clock: clock)
        store.boost(targetID: "post-1", amount: 100)
        store.claim()
        #expect(store.balance == WalletStore.Policy.seededBalance - 100 + 25)
    }

    // MARK: - Change notification

    @Test func mutationsPostScopedChangeNotifications() {
        let store = makeStore()
        let counter = NotificationCounter(object: store)

        store.claim()
        store.boost(targetID: "post-1", amount: 10)
        // Refused mutations are not changes.
        store.claim() // tooEarly
        store.boost(targetID: "post-1", amount: 240) // fills the cap — a change
        store.boost(targetID: "post-1", amount: 10) // cap reached — refused

        #expect(counter.count == 3)
    }
}

/// Counts `WalletStore.didChangeNotification` posts scoped to one store.
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var token: NSObjectProtocol?
    var count: Int { lock.withLock { _count } }
    init(object: WalletStore) {
        token = NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification, object: object, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self._count += 1 }
        }
    }
    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
