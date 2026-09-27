import Foundation
import Testing
@testable import CoreStorage

/// Gems as a currency that can be spent, and the countries an account buys
/// with them.
struct CountryUnlockTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    @Test func aFreshWalletHasTheSeededGems() {
        let wallet = WalletStore(defaults: defaults())
        #expect(wallet.snapshot().gems == WalletStore.Policy.seededGems)
    }

    @Test func spendingGemsIsAllOrNothing() {
        let wallet = WalletStore(defaults: defaults())
        #expect(wallet.spendGems(30) == .spent(remaining: WalletStore.Policy.seededGems - 30))
        #expect(wallet.snapshot().gems == WalletStore.Policy.seededGems - 30)
        #expect(wallet.spendGems(1_000) == .insufficient(gems: WalletStore.Policy.seededGems - 30))
        #expect(wallet.snapshot().gems == WalletStore.Policy.seededGems - 30, "a refused spend took gems")
        #expect(wallet.spendGems(0) == .insufficient(gems: WalletStore.Policy.seededGems - 30))
    }

    /// Unlocks belong to the ACCOUNT: another account sees none of them.
    @Test func unlocksAreTheAccountsOwn() {
        let store = CountryUnlockStore(defaults: defaults())
        #expect(store.unlock("es", for: "acct-a"))
        #expect(!store.unlock("ES", for: "acct-a"), "a second unlock of the same country")
        #expect(store.unlocked(for: "acct-a") == ["ES"])
        #expect(store.unlocked(for: "acct-b").isEmpty)
    }
}
