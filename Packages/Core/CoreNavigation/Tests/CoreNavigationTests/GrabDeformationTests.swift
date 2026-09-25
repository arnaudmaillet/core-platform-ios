import QuartzCore
import Testing
import UIKit
@testable import CoreNavigation

/// The held card's give: a light stretch along the travel, a thinning across
/// it, nothing at rest — drawn in the render tree only.
@MainActor
struct GrabDeformationTests {
    private typealias Tuning = GrabDeformation.Tuning

    @Test func atRestThereIsNoGive() {
        #expect(CATransform3DIsIdentity(GrabDeformation.deformation(for: .zero)))
    }

    @Test func aSidewaysDragStretchesAcrossTheScreenAndThinsTheCard() {
        let t = GrabDeformation.deformation(for: CGPoint(x: 1200, y: 0))
        #expect(t.m11 > 1.01, "no stretch along a horizontal travel: \(t.m11)")
        #expect(t.m22 < 1, "no thinning across it: \(t.m22)")
        #expect(abs(t.m12) < 1e-6 && abs(t.m21) < 1e-6, "a straight drag leaned")
    }

    @Test func aDownwardDragStretchesTheCardDownward() {
        let t = GrabDeformation.deformation(for: CGPoint(x: 0, y: 1200))
        #expect(t.m22 > 1.01, "no stretch along a vertical travel: \(t.m22)")
        #expect(t.m11 < 1)
    }

    /// Very light, whatever the throw.
    @Test func theGiveIsCapped() {
        let t = GrabDeformation.deformation(for: CGPoint(x: 50_000, y: 0))
        #expect(abs(t.m11 - (1 + Tuning.maximumStretch)) < 1e-6)
        #expect(abs(t.m22 - (1 - Tuning.maximumStretch * Tuning.squashPerStretch)) < 1e-6)
    }

    @Test func aTrackedGrabHoldsItsGiveOnTheLayerAndLetsGoOnRelease() {
        let layer = CALayer()
        let give = GrabDeformation(layer: layer, reducesMotion: { false })
        give.track(translation: .zero, at: 10)
        give.track(translation: CGPoint(x: 30, y: 0), at: 10.016)
        give.debugTick()
        #expect(give.debugIsOnTheLayer, "the give is not on the layer")
        #expect(give.current.m11 > 1, "a moving card did not stretch")
        #expect(CATransform3DIsIdentity(layer.transform), "the give wrote the model")

        give.release()
        #expect(!give.debugIsOnTheLayer, "the held give outlived the release")
        #expect(CATransform3DIsIdentity(give.current))
    }

    @Test func underReduceMotionNothingGives() {
        let layer = CALayer()
        let give = GrabDeformation(layer: layer, reducesMotion: { true })
        give.track(translation: .zero, at: 10)
        give.track(translation: CGPoint(x: 30, y: 0), at: 10.016)
        #expect(!give.debugIsOnTheLayer)
    }
}
