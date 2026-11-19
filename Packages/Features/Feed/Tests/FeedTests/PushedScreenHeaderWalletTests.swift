import CoreStorage
import DesignSystem
import Foundation
import Testing
@testable import PostSurfaces

/// The pushed screens' header keeps its wallet observation (#2376). It
/// replaced a selector registration, which lasted exactly as long as the
/// header: a dropped observation would leave the balance frozen, and nothing
/// would visibly fail. PostSurfaces has no test target, so Feed pins it.
@MainActor
struct PushedScreenHeaderWalletTests {
    private static func wallet() -> WalletStore {
        let suite = "pushed-header-wallet-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WalletStore(defaults: defaults, scope: StorageScope(), launchArguments: [])
    }

    /// A change of the wallet redraws the badge at once; once the header
    /// goes, so does its observation, and it never kept the header alive.
    @Test func theBadgeFollowsTheWalletUntilTheHeaderGoes() {
        let wallet = Self.wallet()
        weak var released: PushedScreenHeader?
        autoreleasepool {
            let header = PushedScreenHeader(wallet: wallet, makeWalletSheet: nil, router: nil)
            #expect(wallet.changes.debugObservationCount == 1)
            let before = wallet.balance
            wallet.credit(1_000)
            #expect(header.debugRenderedBalance == (before + 1_000).formattedCompact())
            released = header
        }
        #expect(released == nil, "the observation kept the header alive")
        #expect(wallet.changes.debugObservationCount == 0, "the observation outlived the header")
    }
}
