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

    // MARK: - A flood beyond the disc (#1368)

    /// A capsule hosting the glyph, its words under the flood.
    private func hosted() -> (ring: PullRingGlyphView, region: UIView, words: UILabel) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        window.isHidden = false
        let region = UIView(frame: CGRect(x: 20, y: 20, width: 180, height: 36))
        window.addSubview(region)
        let ring = PullRingGlyphView(image: UIImage(systemName: "magnifyingglass"), diameter: 24)
        ring.frame = CGRect(x: 7, y: 6, width: 24, height: 24)
        region.addSubview(ring)
        ring.floodBeyond(region)
        let words = UILabel()
        words.text = "Release to search"
        ring.floodContent.addSubview(words)
        region.layoutIfNeeded()
        ring.layoutIfNeeded()
        return (ring, region, words)
    }

    /// The region's flood lies under the glyph, carries the host's inverted
    /// content, opens with the arming and drains with the disarming.
    @Test func aRegionFloodsWithTheDisc() {
        let (ring, region, words) = hosted()
        #expect(ring.floodContent.superview === region)
        #expect(region.subviews.firstIndex(of: ring.floodContent)! < region.subviews.firstIndex(of: ring)!,
                "the region's flood covers the glyph")
        #expect(words.isDescendant(of: ring.floodContent))
        #expect(ring.debugRegionFloodAlpha == 0, "the region floods at rest")

        ring.setArmed(true, animated: false)
        #expect(ring.debugRegionFloodAlpha == 1)
        #expect(ring.debugRegionFloodScale == 1, "the region's flood did not open")
        #expect(ring.floodContent.frame == region.bounds)

        ring.setArmed(false, animated: false)
        #expect(ring.debugRegionFloodAlpha == 0, "the drained region still draws")
        #expect(ring.debugRegionFloodScale < 0.01)
    }

    /// ONE circle: the disc's flood is as wide as the region's, so the glyph
    /// inverts exactly when the wavefront crosses it, at every frame.
    @Test func theDiscAndTheRegionFloodAsOneCircle() {
        let (ring, _, _) = hosted()
        let radii = ring.debugFloodRadii
        #expect(radii.region > 24, "the region's flood does not reach past the disc")
        #expect(abs(radii.disc - radii.region) < 0.01, "two circles: \(radii)")
        ring.floodReach = 200
        ring.layoutIfNeeded()
        #expect(ring.debugFloodRadii.region == 200 && ring.debugFloodRadii.disc == 200)
    }

    /// A host that pops itself turns the disc's pop off; a host that fades
    /// the whole meter in shows its track at rest.
    @Test func aHostCanTakeThePopAndShowTheTrack() {
        let (ring, _, _) = hosted()
        ring.popsOnArm = false
        ring.setArmed(true)
        #expect(ring.debugDiscScale == 1, "the disc popped for a host that pops itself")

        let shelf = makeRing()
        #expect(!shelf.debugRingShown)
        shelf.ringShownAtRest = true
        #expect(shelf.debugRingShown, "the track did not show at rest")
    }
}
