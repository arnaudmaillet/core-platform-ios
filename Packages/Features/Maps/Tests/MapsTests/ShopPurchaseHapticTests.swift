import CoreStorage
import DesignSystem
import Testing
import UIKit
@testable import Maps

/// ONE HAPTIC PER PURCHASE (#1884): the outcome's toast plays it — never a
/// second one before the toast.
@MainActor
struct ShopPurchaseHapticTests {
    @Test(arguments: [
        (ProfileItemPurchase.bought(remainingGems: 10), Haptic.success),
        (.insufficientGems(needed: 50, have: 10), .error),
    ])
    func buyingAnItemPlaysOneRole(outcome: ProfileItemPurchase, role: Haptic) {
        let screen = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = screen
        window.isHidden = false
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        let played = HapticRecorder.recording {
            let pending = ShopPurchaseFeedback.pending("Gold", from: screen)
            ShopPurchaseFeedback.show(outcome, title: "Gold", pending: pending)
        }
        #expect(played == [role])
    }
}
