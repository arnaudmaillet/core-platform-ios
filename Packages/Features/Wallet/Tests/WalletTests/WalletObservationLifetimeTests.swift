import CoreStorage
import Foundation
import Testing
import UIKit
@testable import Wallet

/// The wallet's observers keep their observations for exactly as long as
/// they live (#2376). Both replaced a selector registration, which went with
/// the object: a dropped observation would stop them at once, with nothing
/// visibly wrong, and one that outlived them would keep calling into nothing.
@MainActor
struct WalletObservationLifetimeTests {
    private static func wallet() -> WalletStore {
        let suite = "wallet-observation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WalletStore(defaults: defaults, scope: StorageScope(), launchArguments: [])
    }

    /// The root headers' badge redraws on a change of the wallet, and its
    /// observation ends with the installer.
    @Test func theBadgeFollowsTheWalletUntilTheInstallerGoes() {
        let wallet = Self.wallet()
        weak var released: WalletBadgeInstaller?
        autoreleasepool {
            let installer = WalletBadgeInstaller(
                wallet: wallet, presenter: nil, makeSheet: { UIViewController() }, apply: { _ in }
            )
            #expect(wallet.changes.debugObservationCount == 1)
            let before = installer.debugRenderedBalance
            wallet.credit(1_000)
            #expect(installer.debugRenderedBalance != before, "the badge missed the change")
            released = installer
        }
        #expect(released == nil, "the observation kept the installer alive")
        #expect(wallet.changes.debugObservationCount == 0, "the observation outlived the installer")
    }

    /// The refund notices hear the wallet's refunds for as long as the
    /// notifier lives, and no longer.
    @Test func theRefundNoticesListenUntilTheNotifierGoes() {
        let wallet = Self.wallet()
        weak var released: StakeRefundNotifier?
        autoreleasepool {
            let notifier = StakeRefundNotifier(wallet: wallet, window: UIWindow(frame: .zero))
            #expect(wallet.stakeRefunds.debugObservationCount == 1)
            released = notifier
        }
        #expect(released == nil, "the observation kept the notifier alive")
        #expect(wallet.stakeRefunds.debugObservationCount == 0, "the observation outlived the notifier")
    }
}
