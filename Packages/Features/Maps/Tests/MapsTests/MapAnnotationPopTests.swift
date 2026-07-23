import Testing
import UIKit
@testable import Maps

/// The pin pop curve's timing rules.
///
/// Only the pure values are asserted here. The choreographer itself needs a
/// live `MKMapView` to drive — instantiating one contacts MapKit's services,
/// which is exactly the render-server work the CI doctrine keeps out of test
/// targets (see the headless-runner stall that reddened an unrelated suite).
/// What that leaves worth pinning is the arithmetic: the stagger is the one
/// part with a boundary condition, and the collapsed pose is shared by three
/// call sites that must agree.
struct MapAnnotationPopTests {
    @Test("The first pin lands immediately — a stagger that delays pin zero reads as lag")
    func firstPinHasNoDelay() {
        #expect(MapAnnotationPop.stagger(for: 0) == 0)
    }

    @Test("Each pin trails the one before it by a fixed step")
    func staggerIsLinearBelowTheCap() {
        #expect(MapAnnotationPop.stagger(for: 1) == MapAnnotationPop.staggerStep)
        #expect(MapAnnotationPop.stagger(for: 5) == MapAnnotationPop.staggerStep * 5)
    }

    @Test("The stagger caps, so a big page ripples instead of queueing")
    func staggerCaps() {
        // 0.25 / 0.02 = 12.5, so index 12 is the last one below the ceiling
        // (0.24) and 13 is the first the cap actually bites on (0.26 → 0.25).
        let firstCapped = Int((MapAnnotationPop.staggerCap / MapAnnotationPop.staggerStep).rounded(.up))
        #expect(MapAnnotationPop.stagger(for: firstCapped - 1) < MapAnnotationPop.staggerCap)
        #expect(MapAnnotationPop.stagger(for: firstCapped) == MapAnnotationPop.staggerCap)
        #expect(MapAnnotationPop.stagger(for: 500) == MapAnnotationPop.staggerCap)
        // Monotonic and never past the ceiling, at any size.
        for index in 0..<200 {
            let delay = MapAnnotationPop.stagger(for: index)
            #expect(delay <= MapAnnotationPop.staggerCap)
            #expect(delay >= MapAnnotationPop.stagger(for: max(0, index - 1)))
        }
    }

    @Test("A negative index can't mint a negative delay")
    func negativeIndexIsClamped() {
        // `enumerated()` can't produce one, but `startAnimation(afterDelay:)`
        // traps on a negative and this is the only guard against that.
        #expect(MapAnnotationPop.stagger(for: -1) == 0)
    }

    @Test("The whole batch has finished arriving within cap + duration")
    func totalArrivalIsBounded() {
        let worst = MapAnnotationPop.staggerCap + MapAnnotationPop.duration
        #expect(worst < 0.6, "a page of pins should be fully landed inside ~0.6s")
    }

    @Test("The collapsed pose is a uniform half-scale")
    func collapsedTransformIsUniform() {
        let transform = MapAnnotationPop.collapsedTransform
        #expect(transform.a == MapAnnotationPop.collapsedScale)
        #expect(transform.d == MapAnnotationPop.collapsedScale)
        // No translation: a pin must grow from where it belongs, not slide in.
        #expect(transform.tx == 0)
        #expect(transform.ty == 0)
    }

    @Test("The pop spring is under-damped but not bouncy")
    func dampingIsSubtle() {
        // Below 1 so the landing settles rather than switching on; well above
        // the wobble range a marker this small would turn into a jitter.
        #expect(MapAnnotationPop.dampingRatio < 1)
        #expect(MapAnnotationPop.dampingRatio >= 0.7)
    }

    @Test("A fresh animator is inert until started, so it can carry a stagger")
    func animatorStartsIdle() {
        let animator = MapAnnotationPop.makeAnimator()
        #expect(animator.state == .inactive)
        #expect(animator.isRunning == false)
        // Not interruptible-by-default would defeat the whole reason this one
        // surface uses UIViewPropertyAnimator.
        #expect(animator.isInterruptible)
    }
}
