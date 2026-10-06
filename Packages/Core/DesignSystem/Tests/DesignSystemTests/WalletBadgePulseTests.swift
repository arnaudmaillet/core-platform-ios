import Testing
import UIKit
@testable import DesignSystem

/// The points badge's "something is waiting" breath (#580): it breathes only
/// where motion is welcome, and its glow says the same thing standing still.
@MainActor
struct WalletBadgePulseTests {
    private func onScreen(_ badge: WalletBadgeButton) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.addSubview(badge)
        return window
    }

    @Test func aClaimWaitingBreathesAndGlows() {
        let badge = WalletBadgeButton()
        badge.reducesMotion = { false }
        let window = onScreen(badge)
        badge.update(balance: 120, claimAvailable: true)
        #expect(badge.isBreathing)
        #expect(badge.isGlowing)
        _ = window
    }

    /// Reduce Motion or Power Saving: no endless breath to redraw the screen
    /// every frame, the glow alone.
    @Test func underReducedMotionItOnlyGlows() {
        let badge = WalletBadgeButton()
        badge.reducesMotion = { true }
        let window = onScreen(badge)
        badge.update(balance: 120, claimAvailable: true)
        #expect(!badge.isBreathing)
        #expect(badge.isGlowing)
        _ = window
    }

    /// The preference changing while the badge waits is followed at once.
    @Test func turningReducedMotionOnStopsTheBreath() {
        let badge = WalletBadgeButton()
        var reduced = false
        badge.reducesMotion = { reduced }
        let window = onScreen(badge)
        badge.update(balance: 120, claimAvailable: true)
        #expect(badge.isBreathing)
        reduced = true
        NotificationCenter.default.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        #expect(!badge.isBreathing)
        #expect(badge.isGlowing)
        _ = window
    }

    @Test func nothingWaitingNeitherBreathesNorGlows() {
        let badge = WalletBadgeButton()
        badge.reducesMotion = { false }
        let window = onScreen(badge)
        badge.update(balance: 120, claimAvailable: false)
        #expect(!badge.isBreathing)
        #expect(!badge.isGlowing)
        _ = window
    }
}
