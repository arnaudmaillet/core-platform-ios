import CoreModels
import Testing
import UIKit
@testable import Maps

/// Where the selection rim appears, and where it must not.
///
/// The rule is not "selected pills get a ring" — it is "a selected pill that
/// cannot show selection any other way gets a ring". A capsule says it with a
/// blue semibold title; only the title-less circle, whose face is a
/// photograph, has nowhere to put it.
@MainActor
struct MapPillSelectionRingTests {
    @Test("A selected circle wears the rim")
    func aSelectedCircleIsRinged() {
        let ring = MapPillSelectionRing.resolve(selected: true, isCircular: true)

        #expect(ring.isVisible)
        #expect(ring.strokeWidth == 3)
    }

    @Test("An unselected circle keeps the resting glass")
    func anUnselectedCircleHasNoRim() {
        #expect(MapPillSelectionRing.resolve(selected: false, isCircular: true) == .none)
    }

    /// A selected primary EXPANDS into a titled capsule, so by the time it is
    /// selected it is no longer a circle — and its title already turned blue.
    @Test("A selected capsule says it with its title, not a rim")
    func aSelectedCapsuleHasNoRim() {
        #expect(MapPillSelectionRing.resolve(selected: true, isCircular: false) == .none)
    }

    /// The rim is drawn OUTSIDE the pill: the avatar is inset by a hairline of
    /// glass, and a ring drawn inward would consume the one thing separating
    /// an accent rim from a photograph that might itself be blue.
    @Test("The rim sits outside the glass, never over the face")
    func theRimIsDrawnOutward() {
        let ring = MapPillSelectionRing.ringed

        #expect(ring.outset > 0)
        #expect(ring.outset <= MapPillButton.avatarInset)
    }

    /// And it carries a halo, which is what keeps a thin blue line legible
    /// over dark water or park green.
    @Test("The rim carries a halo")
    func theRimGlows() {
        #expect(MapPillSelectionRing.ringed.glowRadius > 0)
        #expect(MapPillSelectionRing.ringed.glowOpacity > 0)
        #expect(MapPillSelectionRing.none.glowOpacity == 0)
    }
}
