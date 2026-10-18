import Testing
import UIKit
@testable import DesignSystem

/// The ring a pull draws around a glyph, then floods (the owner, 2026-10-18:
/// the shelves' pull to "View all", like the inbox's pull to search).
@MainActor
struct PullRingGlyphViewTests {
    private func makeRing() -> PullRingGlyphView {
        let ring = PullRingGlyphView(image: UIImage(systemName: "chevron.right"), diameter: 34)
        ring.layoutIfNeeded()
        return ring
    }

    @Test func atRestTheGlyphIsAlone() {
        let ring = makeRing()
        #expect(!ring.debugRingShown, "a ring showed with no pull")
        #expect(!ring.debugFloodShown)
    }

    @Test func theRingFollowsThePullAndIsFullAtTheThreshold() {
        let ring = makeRing()
        ring.setProgress(0.4)
        #expect(ring.debugRingShown)
        #expect(abs(ring.debugRingStrokeEnd - 0.4) < 0.001)
        ring.setProgress(1.6)
        #expect(ring.debugRingStrokeEnd == 1, "the ring overfilled past the threshold")
        ring.setProgress(0)
        #expect(!ring.debugRingShown, "the ring stayed after the pull ended")
    }

    @Test func armingFloodsAndDisarmingDrains() {
        let ring = makeRing()
        ring.setArmed(true, animated: false)
        #expect(ring.isArmed)
        #expect(ring.debugFloodShown, "armed, the disc did not flood")
        ring.setArmed(false, animated: false)
        #expect(!ring.debugFloodShown, "disarmed, the flood stayed")
    }
}
