import Foundation
import Testing
@testable import CoreStorage

/// The ×10 cartridge pack: bought with gems, ten shots of ten points, packs
/// don't stack, and a shot is spent only by a stake that lands.
struct WalletStakePackTests {
    private typealias Pack = WalletStore.Policy.StakePack

    /// Each test its own suite-named defaults (the runner is parallel).
    private static func defaults() -> UserDefaults {
        let name = "wallet-pack-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
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
        let store = WalletStore(defaults: Self.defaults())
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

    /// One shot: `pointsPerShot` points on the target, one shot off the pack.
    @Test func aShotStakesItsPointsAndUsesOneShot() {
        let store = WalletStore(defaults: Self.defaults())
        store.buyStakePack()
        let balance = store.balance

        let outcome = store.stake(.shot, on: "post-1")

        #expect(outcome == .boosted(
            newBalance: balance - Pack.pointsPerShot, targetTotal: Pack.pointsPerShot, spent: Pack.pointsPerShot
        ))
        #expect(store.stakeShots == Pack.shots - 1)
        #expect(store.boostTotal(forTarget: "post-1") == Pack.pointsPerShot)
    }

    /// Short of points: the stake is refused AND the shot is kept.
    @Test func aRefusedShotIsNotConsumed() {
        let defaults = Self.defaults()
        defaults.set(true, forKey: "wallet.seeded")
        defaults.set(Pack.pointsPerShot - 1, forKey: "wallet.balance")
        let store = WalletStore(defaults: defaults)
        store.buyStakePack()

        #expect(store.stake(.shot, on: "post-1") == .insufficientBalance(balance: Pack.pointsPerShot - 1))
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
        store.stake(.points(WalletStore.Policy.defaultStakeAmount), on: "post-1")
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
