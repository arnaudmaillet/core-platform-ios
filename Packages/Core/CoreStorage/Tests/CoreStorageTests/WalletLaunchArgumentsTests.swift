import Foundation
import Testing
@testable import CoreStorage

/// The wallet's QA launch arguments reach the wallet the app shows (#1388):
/// the app's store starts unscoped, then moves to the member's account.
struct WalletLaunchArgumentsTests {
    private static func defaults() -> UserDefaults {
        let name = "wallet-launch-args-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func gemsReachTheMemberTheScopeMovesTo() {
        let scope = StorageScope()
        let wallet = WalletStore(defaults: Self.defaults(), scope: scope, launchArguments: ["-wallet-gems", "600"])
        #expect(wallet.snapshot().gems == 600)
        scope.owner = .member(account: "acct-1", profile: nil)
        #expect(wallet.snapshot().gems == 600, "the member's own wallet got the flag")
    }

    /// Once per owner per launch: coming back to the member does not hand
    /// the gems back after they were spent.
    @Test func eachOwnerIsServedOnce() {
        let scope = StorageScope()
        let wallet = WalletStore(defaults: Self.defaults(), scope: scope, launchArguments: ["-wallet-gems", "600"])
        scope.owner = .member(account: "acct-1", profile: nil)
        #expect(wallet.spendGems(500) == .spent(remaining: 100))
        scope.owner = .member(account: "acct-2", profile: nil)
        #expect(wallet.snapshot().gems == 600)
        scope.owner = .member(account: "acct-1", profile: nil)
        #expect(wallet.snapshot().gems == 100)
    }

    @Test func noArgumentsChangeNothing() {
        let scope = StorageScope()
        let wallet = WalletStore(defaults: Self.defaults(), scope: scope, launchArguments: [])
        scope.owner = .member(account: "acct-1", profile: nil)
        #expect(wallet.snapshot().gems == WalletStore.Policy.seededGems)
    }
}
