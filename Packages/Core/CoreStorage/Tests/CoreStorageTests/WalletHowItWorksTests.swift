import Foundation
import Testing
@testable import CoreStorage

/// How it works shows once per account (#1480). Synchronous: the swapped
/// defaults never cross an `await`.
struct WalletHowItWorksTests {
    @Test func itShowsOncePerAccountAndNeverToAGuest() throws {
        let suite = "how-it-works-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let saved = WalletHowItWorks.defaults
        WalletHowItWorks.defaults = defaults
        defer {
            WalletHowItWorks.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        let first = StorageScope.Owner.member(account: "a", profile: nil)
        let second = StorageScope.Owner.member(account: "b", profile: "p")
        #expect(WalletHowItWorks.shouldShow(for: first))
        WalletHowItWorks.markSeen(by: first)
        #expect(!WalletHowItWorks.shouldShow(for: first), "once")
        #expect(!WalletHowItWorks.shouldShow(for: .member(account: "a", profile: "other")), "per account, any profile")
        #expect(WalletHowItWorks.shouldShow(for: second), "another account sees it")
        WalletHowItWorks.markSeen(by: first)
        #expect(defaults.stringArray(forKey: WalletHowItWorks.key) == ["a"])
        #expect(!WalletHowItWorks.shouldShow(for: .guest))
    }
}
