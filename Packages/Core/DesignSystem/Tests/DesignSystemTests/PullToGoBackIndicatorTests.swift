import Testing
import UIKit
@testable import DesignSystem

/// The "go back" pull's elastic pill (#2045, #2046): it pops in past a few
/// points, stretches and fills with the pull, turns at the threshold, and
/// reverses under it; one tick per crossing.
@MainActor
struct PullToGoBackIndicatorTests {
    private func indicator(_ direction: PullToGoBackIndicator.Direction) -> PullToGoBackIndicator {
        let indicator = PullToGoBackIndicator(direction: direction, reducesMotion: { true })
        indicator.frame = CGRect(x: 0, y: 0, width: 370, height: PullToGoBackIndicator.height)
        indicator.layoutIfNeeded()
        return indicator
    }

    @Test(arguments: [PullToGoBackIndicator.Direction.up, .down])
    func itPopsStretchesFillsAndTurns(_ direction: PullToGoBackIndicator.Direction) {
        let indicator = indicator(direction)
        let threshold = HeroPullToRefreshView.threshold
        indicator.setPull(2)
        #expect(!indicator.debugShown, "the pill showed before the page left its rest")

        indicator.setPull(threshold * 0.1)
        #expect(indicator.debugShown)
        let narrow = indicator.debugPillWidth
        #expect(abs(narrow - PullToGoBackIndicator.height) < 12, "it does not start as a disc: \(narrow)")

        indicator.setPull(threshold * 0.7)
        #expect(indicator.debugPillWidth > narrow, "it does not stretch with the pull")
        let height = PullToGoBackIndicator.height
        #expect(abs(indicator.debugFillWidth - (height + (indicator.debugPillWidth - height) * 0.7)) < 1,
                "the bubble does not follow the pull")
        #expect(!indicator.isArmed)
        #expect(indicator.debugLine == "Pull to go back")

        indicator.setPull(threshold)
        #expect(indicator.isArmed)
        #expect(indicator.debugSymbolTurned, "the chevron did not turn to ‹")
        #expect(indicator.debugFillWidth == indicator.debugPillWidth, "the pill is not all filled")
        #expect(indicator.debugLine == "Release to go back")

        indicator.setPull(threshold - 1)
        #expect(!indicator.isArmed, "back under the threshold stayed armed")
        #expect(!indicator.debugSymbolTurned)
        #expect(indicator.debugLine == "Pull to go back")

        indicator.setPull(0, isTracking: false)
        #expect(!indicator.debugShown, "the pill outlived the pull")
    }

    /// The pill never runs wider than its room.
    @Test func itFitsItsRoom() {
        let indicator = indicator(.up)
        let size = indicator.sizeThatFits(CGSize(width: 120, height: 500))
        #expect(size.width <= 120)
        #expect(size.height == PullToGoBackIndicator.height)
    }

    /// One tick per crossing under the finger, none on a bounce drifting past.
    @Test func itTicksOncePerCrossing() {
        let threshold = HeroPullToRefreshView.threshold
        let previous = HapticPreference.defaults
        defer { HapticPreference.defaults = previous }
        HapticPreference.defaults = UserDefaults(suiteName: "haptics-\(UUID().uuidString)")!
        let roles: [Haptic] = HapticRecorder.recording {
            let indicator = PullToGoBackIndicator(direction: .up)
            indicator.setPull(threshold + 5)
            indicator.setPull(threshold + 20)
            indicator.setPull(threshold - 10)
            indicator.setPull(threshold + 1, isTracking: false)
        }
        #expect(roles == [.armed], "ticks: \(roles)")
    }
}
