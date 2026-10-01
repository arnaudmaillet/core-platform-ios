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

    // MARK: - The mock seed

    /// A seed unlocks its countries as a purchase would — in the same set.
    @Test func aSeedUnlocksItsCountries() {
        let store = CountryUnlockStore(defaults: defaults())
        #expect(store.seedUnlocks(["es", "JP"], for: "acct-a") == ["ES", "JP"])
        #expect(store.unlocked(for: "acct-a") == ["ES", "JP"])
        #expect(store.unlocked(for: "acct-b").isEmpty, "a seed is one account's")
    }

    /// The seed runs on every launch, and the account's own choices win:
    /// a country it bought stays, a seeded country it gave back stays
    /// locked, across a relaunch (a fresh store over the same defaults).
    @Test func theAccountsOwnUnlocksAndRelocksSurviveARelaunchWithTheSeed() {
        let suite = defaults()
        let seed: Set<String> = ["ES", "JP", "US"]
        let first = CountryUnlockStore(defaults: suite)
        first.seedUnlocks(seed, for: "acct-a")
        #expect(first.unlock("MX", for: "acct-a"))
        #expect(first.relock("JP", for: "acct-a"))
        #expect(!first.relock("KR", for: "acct-a"), "nothing to relock")

        let relaunched = CountryUnlockStore(defaults: suite)
        #expect(relaunched.seedUnlocks(seed, for: "acct-a").isEmpty, "the seed never grants twice")
        #expect(relaunched.unlocked(for: "acct-a") == ["ES", "US", "MX"])
    }

    /// A seed that grows reaches an existing install with its NEW codes
    /// only.
    @Test func aGrownSeedGrantsOnlyItsNewCodes() {
        let suite = defaults()
        let store = CountryUnlockStore(defaults: suite)
        store.seedUnlocks(["ES"], for: "acct-a")
        store.relock("ES", for: "acct-a")
        #expect(CountryUnlockStore(defaults: suite).seedUnlocks(["ES", "BR"], for: "acct-a") == ["BR"])
        #expect(store.unlocked(for: "acct-a") == ["BR"])
    }
}
