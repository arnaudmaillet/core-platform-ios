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

    /// ⚠️ BACK FROM THE BACKGROUND, THE BREATH IS BACK (#783): backgrounding
    /// strips layer animations, and only a re-attach used to re-arm them.
    @Test func comingBackToTheForegroundRearmsTheBreath() {
        let badge = WalletBadgeButton()
        badge.reducesMotion = { false }
        let window = onScreen(badge)
        badge.update(balance: 120, claimAvailable: true)
        #expect(badge.isBreathing, "guard: a claim waiting breathes")

        // What the system does to a backgrounded app's layers.
        func strip(_ layer: CALayer) {
            layer.removeAllAnimations()
            layer.sublayers?.forEach(strip)
        }
        strip(badge.layer)
        #expect(!badge.isBreathing, "guard: the animations were stripped")

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)

        #expect(badge.isBreathing, "the breath stayed gone after coming back")
        _ = window
    }

    /// ⚠️ BACK FROM THE BACKGROUND, THE RING COUNTS AGAIN (#783): stripped,
    /// the ring stood at its model value, full, as if the claim were ready
    /// while the countdown still ran.
    @Test func comingBackToTheForegroundRearmsTheCountdownRing() {
        let badge = WalletBadgeButton()
        badge.reducesMotion = { false }
        let window = onScreen(badge)
        badge.update(
            balance: 120, claimAvailable: false,
            claimProgress: .init(fraction: 0.25, remaining: 3600)
        )
        #expect(badge.isRingCounting, "guard: a running countdown fills the ring")

        // What the system does to a backgrounded app's layers.
        func strip(_ layer: CALayer) {
            layer.removeAllAnimations()
            layer.sublayers?.forEach(strip)
        }
        strip(badge.layer)
        #expect(!badge.isRingCounting, "guard: the animations were stripped")

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)

        #expect(badge.isRingCounting, "the ring stayed still after coming back")
        _ = window
    }
}
