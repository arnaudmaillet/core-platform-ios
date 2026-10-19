import Foundation
import Testing
@testable import CoreStorage

/// The ×100 cartridge pack: bought with gems, three shots of a hundred
/// points, packs don't stack, and a shot is spent only by a stake that lands.
struct WalletStakePackTests {
    private typealias Pack = WalletStore.Policy.StakePack

    /// Each test its own suite-named defaults (the runner is parallel).
    private static func defaults() -> UserDefaults {
        let name = "wallet-pack-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The pack's numbers, pinned: a shot is ×100, and the pack is priced
    /// against the mock economy (`Policy.StakePack`'s note) — three shots for
    /// 50 gems, which the seeded gems buy twice and the seeded points fire
    /// twice.
    @Test func thePackIsThreeShotsOfAHundredForFiftyGems() {
        #expect(Pack.likesPerShot == 100)
        #expect(Pack.shots == 3)
        #expect(Pack.price == 50)
        #expect(WalletStore.Policy.seededGems >= 2 * Pack.price)
        #expect(WalletStore.Policy.seededBalance / Pack.likesPerShot == 2)
        // A post holds two shots, never a third.
        #expect(WalletStore.Policy.perTargetBoostCap / Pack.likesPerShot == 2)
    }

    @Test func aFreshWalletHasNoPack() {
        let store = WalletStore(defaults: Self.defaults())
        #expect(store.stakeShots == 0)
        #expect(store.snapshot().stakeShots == 0)
    }

    @Test func buyingDeductsTheGemsAndLoadsTheShots() {
        let store = WalletStore(defaults: Self.defaults())
        let gems = store.snapshot().gems

        #expect(store.buyStakePack() == .bought(shots: Pack.shots, remainingGems: gems - Pack.price))

        #expect(store.snapshot().gems == gems - Pack.price)
        #expect(store.stakeShots == Pack.shots)
        #expect(store.snapshot().stakeShots == Pack.shots)
    }

    /// Packs don't stack: refused while a single shot is left, nothing charged.
    @Test func aPackCannotBeBoughtWhileTheCurrentOneHasShots() {
        // Points for every shot of two packs: the seeded 250 fire only two.
        let defaults = Self.defaults()
        defaults.set(true, forKey: "wallet.seeded")
        defaults.set(2 * Pack.shots * Pack.likesPerShot, forKey: "wallet.balance")
        let store = WalletStore(defaults: defaults)
        store.buyStakePack()
        for _ in 0..<(Pack.shots - 1) {
            store.stake(.shot, on: "post-\(UUID().uuidString)")
        }
        #expect(store.stakeShots == 1)
        let gems = store.snapshot().gems

        #expect(store.buyStakePack() == .packStillActive(shotsLeft: 1))
        #expect(store.snapshot().gems == gems)
        #expect(store.stakeShots == 1)

        // The last shot empties it; then a new pack can be bought.
        store.stake(.shot, on: "post-last")
        #expect(store.stakeShots == 0)
        #expect(store.buyStakePack() == .bought(shots: Pack.shots, remainingGems: gems - Pack.price))
    }

    @Test func aPackTheGemsCannotCoverChangesNothing() {
        let defaults = Self.defaults()
        let store = WalletStore(defaults: defaults)
        let gems = store.snapshot().gems
        // Spend down to one gem short of the price.
        _ = store.spendGems(gems - (Pack.price - 1))

        #expect(store.buyStakePack() == .insufficientGems(needed: Pack.price, have: Pack.price - 1))
        #expect(store.stakeShots == 0)
        #expect(store.snapshot().gems == Pack.price - 1)
    }

    /// One shot: `likesPerShot` likes on the target, one shot off the pack.
    @Test func aShotStakesItsPointsAndUsesOneShot() {
        let store = WalletStore(defaults: Self.defaults())
        store.buyStakePack()
        let balance = store.balance

        let outcome = store.stake(.shot, on: "post-1")

        #expect(outcome == .boosted(
            newBalance: balance - Pack.likesPerShot, targetTotal: Pack.likesPerShot, spent: Pack.likesPerShot
        ))
        #expect(store.stakeShots == Pack.shots - 1)
        #expect(store.boostTotal(forTarget: "post-1") == Pack.likesPerShot)
    }

    /// Short of likes: the stake is refused AND the shot is kept.
    @Test func aRefusedShotIsNotConsumed() {
        let defaults = Self.defaults()
        defaults.set(true, forKey: "wallet.seeded")
        defaults.set(Pack.likesPerShot - 1, forKey: "wallet.balance")
        let store = WalletStore(defaults: defaults)
        store.buyStakePack()

        #expect(store.stake(.shot, on: "post-1") == .insufficientBalance(balance: Pack.likesPerShot - 1))
        #expect(store.stakeShots == Pack.shots)
        #expect(store.boostTotal(forTarget: "post-1") == 0)
    }

    /// A full post refuses the shot too — and keeps it.
    @Test func aShotOnAFullPostIsNotConsumed() {
        let store = WalletStore(defaults: Self.defaults())
        store.buyStakePack()
        store.boost(targetID: "post-1", amount: WalletStore.Policy.perTargetBoostCap)

        #expect(store.stake(.shot, on: "post-1") == .targetCapReached(targetTotal: WalletStore.Policy.perTargetBoostCap))
        #expect(store.stakeShots == Pack.shots)
    }

    /// A shot is never clamped: on a post with room for less than a whole
    /// shot it is REFUSED with the room left — the menu's "Only 50 points more
    /// fit on this post" — and kept, while a plain amount there still clamps.
    @Test func aShotThatDoesNotFitWholeIsRefusedNotClamped() {
        let defaults = Self.defaults()
        defaults.set(true, forKey: "wallet.seeded")
        defaults.set(1_000, forKey: "wallet.balance")
        let store = WalletStore(defaults: defaults)
        store.buyStakePack()
        store.stake(.shot, on: "post-1")
        store.stake(.shot, on: "post-1")
        #expect(store.boostTotal(forTarget: "post-1") == 200)
        let balance = store.balance

        #expect(store.stake(.shot, on: "post-1") == .shotDoesNotFit(room: 50))
        #expect(store.stakeShots == Pack.shots - 2)
        #expect(store.balance == balance)
        #expect(store.boostTotal(forTarget: "post-1") == 200)

        // One point short of a whole shot is still short.
        store.boost(targetID: "post-2", amount: WalletStore.Policy.perTargetBoostCap - Pack.likesPerShot + 1)
        #expect(store.stake(.shot, on: "post-2") == .shotDoesNotFit(room: Pack.likesPerShot - 1))
        #expect(store.stakeShots == Pack.shots - 2)

        // Exactly a shot's room: it lands, whole.
        store.boost(targetID: "post-3", amount: WalletStore.Policy.perTargetBoostCap - Pack.likesPerShot)
        let landed = store.stake(.shot, on: "post-3")
        #expect(landed == .boosted(
            newBalance: store.balance, targetTotal: WalletStore.Policy.perTargetBoostCap, spent: Pack.likesPerShot
        ))
        #expect(store.stakeShots == Pack.shots - 3)
    }

    /// The menu's order: no room is answered before no points.
    @Test func aShotIsJudgedOnRoomBeforeBalance() {
        let defaults = Self.defaults()
        defaults.set(true, forKey: "wallet.seeded")
        defaults.set(WalletStore.Policy.perTargetBoostCap - Pack.likesPerShot + 1 + 10, forKey: "wallet.balance")
        let store = WalletStore(defaults: defaults)
        store.buyStakePack()
        store.boost(targetID: "post-1", amount: WalletStore.Policy.perTargetBoostCap - Pack.likesPerShot + 1)
        // 10 points left, room for 99: the room is what refuses it.
        #expect(store.stake(.shot, on: "post-1") == .shotDoesNotFit(room: Pack.likesPerShot - 1))
    }

    @Test func aShotWithoutAPackChangesNothing() {
        let store = WalletStore(defaults: Self.defaults())
        let balance = store.balance
        #expect(store.stake(.shot, on: "post-1") == .noShotsLeft)
        #expect(store.balance == balance)
        #expect(store.boostTotal(forTarget: "post-1") == 0)
    }

    /// A plain stake never touches the pack.
    @Test func aPlainStakeLeavesThePackAlone() {
        let store = WalletStore(defaults: Self.defaults())
        store.buyStakePack()
        store.stake(.likes(WalletStore.Policy.defaultStakeAmount), on: "post-1")
        #expect(store.stakeShots == Pack.shots)
    }

    /// The pack is the wallet's: what is left survives a relaunch, as the
    /// gems and the balance do.
    @Test func theShotsLeftSurviveRelaunch() {
        let defaults = Self.defaults()
        let first = WalletStore(defaults: defaults)
        first.buyStakePack()
        first.stake(.shot, on: "post-1")
        first.stake(.shot, on: "post-2")
        let gems = first.snapshot().gems

        let relaunched = WalletStore(defaults: defaults)
        #expect(relaunched.stakeShots == Pack.shots - 2)
        #expect(relaunched.snapshot().gems == gems)
        #expect(relaunched.buyStakePack() == .packStillActive(shotsLeft: Pack.shots - 2))
    }

    @Test func buyingAndShootingPostScopedChangeNotifications() async {
        let store = WalletStore(defaults: Self.defaults())
        let center = NotificationCenter.default
        let counter = Counter()
        let token = center.addObserver(forName: WalletStore.didChangeNotification, object: store, queue: nil) { _ in
            counter.increment()
        }
        defer { center.removeObserver(token) }

        store.buyStakePack()
        store.stake(.shot, on: "post-1")
        store.buyStakePack() // refused: no post
        #expect(counter.value == 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }

}

extension WalletStakePackTests {
    /// Several packs (backend #941): a bigger one loads its own shots for its
    /// own price, and remembers which it was; they still don't stack.
    @Test func aBiggerPackLoadsItsShotsAndIsRemembered() throws {
        let defaults = Self.defaults()
        // Gems granted up front: the seeded 100 buy only the smallest pack.
        defaults.set(1_000, forKey: StorageScope.shared.accountKey("wallet.gemsGranted"))
        let store = WalletStore(defaults: defaults)
        let tier = try #require(Pack.tiers.first { $0.shots == 10 })
        let gems = store.snapshot().gems
        #expect(gems >= tier.price, "precondition: the seed affords the 10-shot pack")
        #expect(store.stakePackTierID == nil)
        #expect(store.buyStakePack(tier) == .bought(shots: 10, remainingGems: gems - tier.price))
        #expect(store.stakeShots == 10)
        #expect(store.stakePackTierID == tier.id)
        #expect(store.buyStakePack(Pack.standard) == .packStillActive(shotsLeft: 10))
    }

    @Test func tiersAreSmallestFirstAndCheaperAShotAsTheyGrow() {
        #expect(Pack.tiers.map(\.shots) == Pack.tiers.map(\.shots).sorted())
        #expect(Pack.standard.shots == Pack.shots && Pack.standard.price == Pack.price)
        let perShot = Pack.tiers.map { Double($0.price) / Double($0.shots) }
        #expect(perShot == perShot.sorted(by: >))
    }
}
