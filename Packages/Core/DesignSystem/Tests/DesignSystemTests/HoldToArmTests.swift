import CoreGraphics
import Testing
import UIKit
@testable import DesignSystem

/// A hold fires only when it was completed, and only on the lift.
struct HoldToArmTests {
    private let origin = CGPoint(x: 100, y: 100)

    @Test func revealsOnBeginAndFillsLinearlyWithTime() {
        var hold = HoldToArm(fillDuration: 0.6)
        #expect(hold.begin(at: 10, location: origin) == .revealed)
        #expect(hold.progress(at: 10) == 0)
        #expect(abs(hold.progress(at: 10.3) - 0.5) < 0.0001)
        #expect(hold.phase == .filling(since: 10))
    }

    @Test func armsOnceFullAndNotBefore() {
        var hold = HoldToArm(fillDuration: 0.6)
        _ = hold.begin(at: 0, location: origin)
        #expect(hold.tick(at: 0.59) == nil)
        #expect(hold.tick(at: 0.6) == .armed)
        #expect(hold.phase == .armed)
        // Once, not every frame after.
        #expect(hold.tick(at: 0.7) == nil)
        #expect(hold.progress(at: 5) == 1)
    }

    @Test func liftingBeforeFullRetractsAndNeverFires() {
        var hold = HoldToArm(fillDuration: 0.6)
        _ = hold.begin(at: 0, location: origin)
        #expect(hold.end(at: 0.3) == .retracted)
        #expect(hold.phase == .idle)
    }

    @Test func liftingWhileArmedFires() {
        var hold = HoldToArm(fillDuration: 0.6)
        _ = hold.begin(at: 0, location: origin)
        _ = hold.tick(at: 0.7)
        #expect(hold.end(at: 1.5) == .fired)
        #expect(hold.phase == .idle)
    }

    /// The display link may not have ticked in the frame the gauge filled:
    /// a lift at or after full still counts.
    @Test func aLiftInTheFrameItFillsStillFires() {
        var hold = HoldToArm(fillDuration: 0.6)
        _ = hold.begin(at: 0, location: origin)
        #expect(hold.end(at: 0.61) == .fired)
    }

    @Test func driftingPastTheLimitAbandonsAndTheLiftDoesNothing() {
        var hold = HoldToArm(fillDuration: 0.6, abandonDistance: 60)
        _ = hold.begin(at: 0, location: origin)
        #expect(hold.move(to: CGPoint(x: 140, y: 140), at: 0.2) == nil, "56pt is inside the limit")
        #expect(hold.move(to: CGPoint(x: 150, y: 140), at: 0.3) == .abandoned)
        // Coming back does not re-arm, and time does not arm it either.
        #expect(hold.move(to: origin, at: 0.4) == nil)
        #expect(hold.tick(at: 2) == nil)
        #expect(hold.end(at: 2) == nil)
        #expect(hold.phase == .idle)
    }

    @Test func driftingAwayWhileArmedAbandonsToo() {
        var hold = HoldToArm(fillDuration: 0.6, abandonDistance: 60)
        _ = hold.begin(at: 0, location: origin)
        _ = hold.tick(at: 0.6)
        #expect(hold.move(to: CGPoint(x: 100, y: 20), at: 0.8) == .abandoned)
        #expect(hold.end(at: 0.9) == nil)
    }

    @Test func movingWithinTheLimitStillArms() {
        var hold = HoldToArm(fillDuration: 0.6)
        _ = hold.begin(at: 0, location: origin)
        #expect(hold.move(to: CGPoint(x: 110, y: 95), at: 0.65) == .armed)
    }

    @Test func aCancelNeverFiresEvenWhenArmed() {
        var hold = HoldToArm(fillDuration: 0.6)
        _ = hold.begin(at: 0, location: origin)
        _ = hold.tick(at: 1)
        #expect(hold.cancel() == .retracted)
        #expect(hold.phase == .idle)
        #expect(hold.cancel() == nil)
    }

    @Test func aSecondBeginWhileEngagedIsIgnored() {
        var hold = HoldToArm(fillDuration: 0.6)
        _ = hold.begin(at: 0, location: origin)
        #expect(hold.begin(at: 0.3, location: .zero) == nil)
        #expect(hold.phase == .filling(since: 0))
    }

    @Test func theShippedTimingIsUnderASecondWithTheRecognitionDelay() {
        // The recogniser's 0.22 s plus the fill: a shortcut has to beat the
        // two taps it replaces.
        #expect(HoldToArm.Metrics.fillDuration >= 0.5)
        #expect(0.22 + HoldToArm.Metrics.fillDuration < 1)
    }
}

/// The disc says "armed" with more than the ring, and never outlives its exit.
@MainActor
struct HoldRingDiscViewTests {
    @Test func progressIsClampedAndDrawnWithoutImplicitAnimation() {
        let disc = HoldRingDiscView(symbolName: "camera.fill", reducesMotion: { true })
        disc.setProgress(1.4)
        #expect(disc.progress == 1)
        #expect(disc.debugRingStrokeEnd == 1)
        disc.setProgress(-1)
        #expect(disc.progress == 0)
    }

    @Test func armingFillsTheRingAndTheDisc() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.tintColor = .systemBlue
        window.isHidden = false
        let disc = HoldRingDiscView(symbolName: "camera.fill", reducesMotion: { true })
        window.addSubview(disc)
        disc.appear()
        #expect(disc.debugHasGlass)
        #expect(disc.debugFillAlpha == 0, "the resting disc is clear glass")
        disc.setProgress(0.4)
        disc.setArmed(true)
        #expect(disc.isArmed)
        #expect(disc.progress == 1)
        #expect(disc.debugHasGlass, "the glass stays put under the fill")
        #expect(disc.debugFillAlpha == 1, "the armed disc wears the accent")
    }

    @Test func noGlassIsBuiltOffWindow() {
        // Building a real effect off-screen stalls headless simulators
        // (`ToastView`'s rule).
        let disc = HoldRingDiscView(symbolName: "camera.fill", reducesMotion: { true })
        disc.appear()
        #expect(!disc.debugHasGlass)
    }

    @Test func dismissRemovesTheDiscOnceAndIgnoresASecondCall() async throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let disc = HoldRingDiscView(symbolName: "camera.fill", reducesMotion: { true })
        host.addSubview(disc)
        var completions = 0
        disc.dismiss(.retract) { completions += 1 }
        disc.dismiss(.launch) { completions += 1 }
        #expect(disc.isDismissing)
        #expect(disc.progress == 0)
        for _ in 0..<100 where disc.superview != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(disc.superview == nil)
        #expect(completions == 1)
    }

    /// With `firesWhenFull` the gauge filling IS the decision: it fires there
    /// and then, and the lift that follows does nothing.
    @Test func firesTheMomentItFillsWhenAsked() {
        var hold = HoldToArm(fillDuration: 0.6, firesWhenFull: true)
        #expect(hold.begin(at: 0, location: .zero) == .revealed)
        #expect(hold.tick(at: 0.3) == nil)
        #expect(hold.tick(at: 0.6) == .fired)
        #expect(hold.phase == .spent)
        #expect(hold.progress(at: 0.7) == 1)
        // Spent: moving far, ticking or lifting fire nothing more.
        #expect(hold.move(to: CGPoint(x: 500, y: 0), at: 0.8) == nil)
        #expect(hold.tick(at: 0.9) == nil)
        #expect(hold.end(at: 1.0) == nil)
        #expect(hold.phase == .idle)
    }

    /// A lift before the gauge fills still retracts.
    @Test func anEarlyLiftStillRetractsWhenFiringOnFull() {
        var hold = HoldToArm(fillDuration: 0.6, firesWhenFull: true)
        _ = hold.begin(at: 0, location: .zero)
        #expect(hold.end(at: 0.3) == .retracted)
    }
}
