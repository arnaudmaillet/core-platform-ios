import Foundation
import Testing
@testable import CoreStorage

private func makeDefaults() -> UserDefaults {
    let name = "storage-scope-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Guest mode §6.6: what expresses an identity is kept per profile or per
/// account, so the next person on this device never sees the last one's.
struct StorageScopeTests {
    private let defaults = makeDefaults()

    @Test func keysFollowTheOwner() {
        let scope = StorageScope()
        #expect(scope.profileKey("k") == "k", "unscoped keeps the original key")
        scope.owner = .guest
        #expect(scope.profileKey("k") == "k@guest")
        #expect(scope.accountKey("k") == "k@guest")
        scope.owner = .member(account: "A", profile: nil)
        #expect(scope.profileKey("k") == "k@a:A", "no profile yet: the account's")
        scope.owner = .member(account: "A", profile: "P")
        #expect(scope.profileKey("k") == "k@p:P")
        #expect(scope.accountKey("k") == "k@a:A")
    }

    @Test func aChangeIsAnnouncedOnce() {
        let scope = StorageScope()
        final class Count: @unchecked Sendable { var value = 0 }
        let posts = Count()
        let token = NotificationCenter.default.addObserver(
            forName: StorageScope.didChangeNotification, object: scope, queue: nil
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        scope.owner = .guest
        scope.owner = .guest
        scope.owner = .member(account: "A", profile: nil)
        #expect(posts.value == 2)
    }

    @Test func savesBelongToTheProfileThatMadeThem() {
        let scope = StorageScope(owner: .member(account: "A", profile: "P1"))
        let store = PostBookmarkStore(defaults: defaults, scope: scope)
        store.toggle("post-1")
        scope.owner = .member(account: "A", profile: "P2")
        #expect(store.savedPostIDs.isEmpty, "another profile, another pile")
        scope.owner = .member(account: "B", profile: "Q")
        #expect(store.savedPostIDs.isEmpty, "another account, another pile")
        scope.owner = .guest
        #expect(store.savedPostIDs.isEmpty, "a guest has none")
        scope.owner = .member(account: "A", profile: "P1")
        #expect(store.savedPostIDs == ["post-1"], "nothing was wiped")
    }

    @Test func whatWasThereBeforeIsAdoptedByTheFirstMemberOnly() {
        defaults.set(["old-post"], forKey: "profile.savedPostIDs")
        let scope = StorageScope(owner: .guest)
        let store = PostBookmarkStore(defaults: defaults, scope: scope)
        #expect(store.savedPostIDs.isEmpty, "a guest never inherits it")
        scope.owner = .member(account: "A", profile: "P1")
        #expect(store.savedPostIDs == ["old-post"])
        scope.owner = .member(account: "B", profile: "Q")
        #expect(store.savedPostIDs.isEmpty, "adopted once, by one profile")
        #expect(defaults.object(forKey: "profile.savedPostIDs") == nil)
    }

    @Test func aGuestHoldsNoWallet() {
        let scope = StorageScope(owner: .guest)
        let wallet = WalletStore(defaults: defaults, scope: scope)
        #expect(wallet.balance == 0)
        #expect(wallet.snapshot().gems == 0)
        wallet.seedDemoStakesIfNeeded(targetIDs: ["post-1"])
        #expect(wallet.boostTotal(forTarget: "post-1") == 0, "no stakes shown on a guest's posts")
    }

    /// A guest's like reaches the member gate: judged against an empty
    /// wallet, every like control would grey out and never ask.
    @Test func aGuestsStakeIsNeverUnaffordable() {
        let scope = StorageScope(owner: .guest)
        let wallet = WalletStore(defaults: defaults, scope: scope)
        #expect(wallet.balance == 0)
        #expect(wallet.stakeableBalance >= WalletStore.Policy.perTargetBoostCap)
        scope.owner = .member(account: "A", profile: nil)
        #expect(wallet.stakeableBalance == wallet.balance, "a member is judged against their wallet")
    }

    @Test func eachAccountGetsItsOwnWallet() {
        let scope = StorageScope(owner: .guest)
        let wallet = WalletStore(defaults: defaults, scope: scope)
        wallet.seedDemoStakesIfNeeded(targetIDs: ["post-1"])

        scope.owner = .member(account: "A", profile: nil)
        #expect(wallet.balance == WalletStore.Policy.seededBalance, "a member's first wallet is seeded")
        #expect(wallet.boostTotal(forTarget: "post-1") > 0, "with the demo plan asked for earlier")
        wallet.credit(50)

        scope.owner = .member(account: "B", profile: nil)
        #expect(wallet.balance == WalletStore.Policy.seededBalance, "B never sees A's credit")

        scope.owner = .member(account: "A", profile: "P")
        #expect(wallet.balance == WalletStore.Policy.seededBalance + 50, "a profile switch keeps the account's wallet")
    }

    @Test @MainActor func draftsBelongToTheProfile() throws {
        let name = "drafts-scope-\(UUID().uuidString)"
        let scope = StorageScope(owner: .member(account: "A", profile: "P1"))
        let store = PostDraftStore(name: name, scope: scope)
        store.save("first thought")
        scope.owner = .member(account: "A", profile: "P2")
        // The store re-reads on the main queue.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(store.drafts.isEmpty)
        scope.owner = .member(account: "A", profile: "P1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(store.drafts.map(\.text) == ["first thought"])
    }
}
