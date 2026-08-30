import CoreGraphics
import Testing
@testable import CoreNavigation

/// Property sweeps over the catch-and-release contracts — seeded, so a red
/// run names the exact inputs that produced it.
///
/// The example-based suites (`ZoomFlightGrabHandoffTests`,
/// `CaughtReleaseContractTests`) pin the stories; these pin the SHAPE of the
/// functions between the stories, which is where an off-by-one in a threshold
/// comparison or a sign slip in a projection hides from examples.
struct ZoomGrabPropertySweepTests {
    // MARK: - The caught-release contract

    /// The exact decision boundaries, walked from both sides: the fraction
    /// threshold is inclusive, the flick thresholds are inclusive, and one
    /// point past each flips the answer.
    @Test func theCaughtReleaseBoundariesAreExactlyWhereTheContractSaysTheyAre() {
        // Bare release: decided by the catch fraction alone.
        #expect(!ZoomTransitionGeometry.caughtReleaseCompletes(caughtAt: 0.74, velocityTowardEnd: 0))
        #expect(ZoomTransitionGeometry.caughtReleaseCompletes(caughtAt: 0.75, velocityTowardEnd: 0))
        #expect(ZoomTransitionGeometry.caughtReleaseCompletes(caughtAt: 0.76, velocityTowardEnd: 0))
        // A flick toward the end wins at the threshold, from any fraction.
        #expect(ZoomTransitionGeometry.caughtReleaseCompletes(caughtAt: 0, velocityTowardEnd: 900))
        #expect(!ZoomTransitionGeometry.caughtReleaseCompletes(caughtAt: 0, velocityTowardEnd: 899))
        // A flick back wins at the threshold, even on a flight caught landed.
        #expect(!ZoomTransitionGeometry.caughtReleaseCompletes(caughtAt: 0.99, velocityTowardEnd: -900))
        #expect(ZoomTransitionGeometry.caughtReleaseCompletes(caughtAt: 0.99, velocityTowardEnd: -899))
    }

    /// Swept: a decisive flick decides IN ITS DIRECTION whatever the fraction,
    /// and below flick speed the fraction alone decides — the drag distance
    /// never appears in the contract at all.
    @Test func aFlickAlwaysWinsAndADragNeverDoes() {
        var random = SeededRandom(seed: 0xF11C)
        for _ in 0..<500 {
            let caught = CGFloat(random.nextUnit())
            let velocity = CGFloat(random.nextUnit() * 4000 - 2000)
            let completes = ZoomTransitionGeometry.caughtReleaseCompletes(
                caughtAt: caught, velocityTowardEnd: velocity
            )
            if velocity >= 900 {
                #expect(completes, "forward flick refused at caught=\(caught) v=\(velocity)")
            } else if velocity <= -900 {
                #expect(!completes, "backward flick ignored at caught=\(caught) v=\(velocity)")
            } else {
                #expect(completes == (caught >= 0.75),
                        "bare release contradicted the catch point at caught=\(caught) v=\(velocity)")
            }
        }
    }

    // MARK: - The handoff's one-way street, under arbitrary event storms

    /// Whatever order touches, grabs and releases arrive in, the machine
    /// decides at most once, never resurrects, and never issues a command
    /// from a spent state. This is the invariant the UIKit driver leans on
    /// when a gesture recogniser delivers events after `detach()`.
    @Test func theHandoffDecidesAtMostOnceUnderAnyEventOrder() {
        var random = SeededRandom(seed: 0xDEC1DE)
        for _ in 0..<300 {
            var handoff = ZoomFlightGrabHandoff(
                advancesOnDownwardDrag: random.nextUnit() < 0.5, span: 874
            )
            var decisions = 0
            var commands = 0
            for _ in 0..<12 {
                switch random.next(in: 0...3) {
                case 0:
                    if handoff.touchDown() != nil { commands += 1 }
                case 1:
                    if handoff.touchUp() != nil { commands += 1; decisions += 1 }
                case 2:
                    _ = handoff.grabBegan(atFraction: CGFloat(random.nextUnit()))
                default:
                    if handoff.released(
                        verticalTranslation: CGFloat(random.nextUnit() * 800 - 400),
                        verticalVelocity: CGFloat(random.nextUnit() * 4000 - 2000)
                    ) != nil { decisions += 1 }
                }
                if handoff.phase == .decided {
                    // A spent handoff must refuse everything from here on.
                    // (Hoisted: `#expect` cannot expand mutating member calls.)
                    let lateTouch = handoff.touchDown()
                    let lateLift = handoff.touchUp()
                    let lateGrab = handoff.grabBegan(atFraction: 0.5)
                    let lateRelease = handoff.released(verticalTranslation: 0, verticalVelocity: 0)
                    #expect(lateTouch == nil)
                    #expect(lateLift == nil)
                    #expect(!lateGrab)
                    #expect(lateRelease == nil)
                }
            }
            #expect(decisions <= 1, "a handoff decided twice")
            #expect(commands <= 2, "more commands than a freeze and a resume")
        }
    }

    /// The scrub fraction is measured from the CATCH POINT and clamped — a
    /// grab at 0.6 that drags nowhere stays at 0.6, and no translation can
    /// push it outside the unit interval.
    @Test func theScrubFractionAnchorsAtTheCatchAndClamps() {
        var random = SeededRandom(seed: 0x5C1B)
        for _ in 0..<200 {
            var handoff = ZoomFlightGrabHandoff(advancesOnDownwardDrag: true, span: 874)
            let caught = CGFloat(random.nextUnit())
            let began = handoff.grabBegan(atFraction: caught)
            #expect(began)
            #expect(abs(handoff.fraction(forVerticalTranslation: 0) - caught) < 0.0001)
            let anywhere = CGFloat(random.nextUnit() * 40000 - 20000)
            let fraction = handoff.fraction(forVerticalTranslation: anywhere)
            #expect(fraction >= 0 && fraction <= 1)
        }
    }

    /// The free channel passes ~1:1 near the origin and never exceeds its
    /// caps, whatever the finger does — the "follows the hand without
    /// promising departure" contract, as arithmetic.
    @Test func theFreeChannelIsOneToOneNearTheGrabAndCappedFarFromIt() {
        let handoff = ZoomFlightGrabHandoff(advancesOnDownwardDrag: false, span: 874)
        // Near the origin: residual ≈ translation.
        let near = handoff.freeOffset(
            translation: CGPoint(x: 8, y: 12), railDelta: .zero
        )
        #expect(abs(near.x - 8) < 1)
        #expect(abs(near.y - 12) < 1)
        // Far away: asymptotic to the caps, never past them.
        var random = SeededRandom(seed: 0xF4EE)
        for _ in 0..<200 {
            let offset = handoff.freeOffset(
                translation: CGPoint(
                    x: random.nextUnit() * 8000 - 4000,
                    y: random.nextUnit() * 8000 - 4000
                ),
                railDelta: CGPoint(
                    x: random.nextUnit() * 400 - 200,
                    y: random.nextUnit() * 400 - 200
                )
            )
            #expect(abs(offset.x) < handoff.horizontalDriftLimit)
            #expect(abs(offset.y) < handoff.verticalDriftLimit)
        }
    }

    // MARK: - Continuation and return velocities: signed, clamped

    /// The continuation seed always lands in UIKit's safe window (±3), and a
    /// hand moving toward the outcome's target seeds positive — both legs,
    /// both outcomes.
    @Test func continuationVelocityIsClampedAndSignedTowardTheTarget() {
        var random = SeededRandom(seed: 0xC0A57)
        for _ in 0..<400 {
            let direction: CGFloat = random.nextUnit() < 0.5 ? 1 : -1
            let towardEnd = random.nextUnit() < 0.5
            let raw = CGFloat(random.nextUnit() * 40000 - 20000)
            let seed = ZoomFlightGrabHandoff.continuationVelocity(
                rawVerticalVelocity: raw,
                atProgress: CGFloat(random.nextUnit()),
                towardEnd: towardEnd, direction: direction, span: 874
            )
            #expect(seed >= -3 && seed <= 3)
            let towardTarget = (towardEnd ? 1 : -1) * direction * raw
            if towardTarget > 0 {
                #expect(seed >= 0, "hand moving toward the target seeded backwards")
            } else if towardTarget < 0 {
                #expect(seed <= 0, "hand moving away seeded forwards")
            }
        }
    }

    /// The free channel's return spring: seeded from the projection of the
    /// hand onto the way home — positive when the hand is already returning,
    /// negative mid-fling away (momentum carried, then reeled back), zero for
    /// an offset too small to spring across. Always within UIKit's window.
    @Test func freeChannelReturnVelocityProjectsTheHandOntoTheWayHome() {
        // Straight cases first, where the sign is legible by eye.
        let away = ZoomFlightGrabHandoff.freeChannelReturnVelocity(
            offset: CGPoint(x: 100, y: 0), handVelocity: CGPoint(x: 500, y: 0)
        )
        #expect(away < 0)
        let home = ZoomFlightGrabHandoff.freeChannelReturnVelocity(
            offset: CGPoint(x: 100, y: 0), handVelocity: CGPoint(x: -500, y: 0)
        )
        #expect(home > 0)
        #expect(ZoomFlightGrabHandoff.freeChannelReturnVelocity(
            offset: .zero, handVelocity: CGPoint(x: 4000, y: 4000)
        ) == 0)
        // Then the sweep for the clamp.
        var random = SeededRandom(seed: 0x4E7)
        for _ in 0..<300 {
            let seed = ZoomFlightGrabHandoff.freeChannelReturnVelocity(
                offset: CGPoint(
                    x: random.nextUnit() * 600 - 300, y: random.nextUnit() * 600 - 300
                ),
                handVelocity: CGPoint(
                    x: random.nextUnit() * 20000 - 10000, y: random.nextUnit() * 20000 - 10000
                )
            )
            #expect(seed >= -3 && seed <= 3)
        }
    }

    // MARK: - Recovering the caught fraction from what is on screen

    /// The recovery inverts the pose on both axes, picks the longer travel,
    /// clamps overshoot, and refuses endpoints too alike to divide by — the
    /// answer the freeze re-aims the percent driver with, so a wrong number
    /// here is a card that snaps the instant it is touched.
    @Test func caughtFractionInvertsThePoseOnWhicheverAxisTravelsFurther() {
        // Height travels further: recovered from height.
        let byHeight = ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 200, height: 500),
            start: CGSize(width: 120, height: 90),
            end: CGSize(width: 402, height: 874)
        )
        #expect(abs((byHeight ?? -1) - (500 - 90) / (874 - 90)) < 0.0001)
        // Width travels further: recovered from width.
        let byWidth = ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 300, height: 100),
            start: CGSize(width: 100, height: 96),
            end: CGSize(width: 500, height: 100)
        )
        #expect(abs((byWidth ?? -1) - 0.5) < 0.0001)
        // Overshoot (a spring past its target) clamps rather than extrapolates.
        let overshot = ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 420, height: 900),
            start: CGSize(width: 120, height: 90),
            end: CGSize(width: 402, height: 874)
        )
        #expect(overshot == 1)
        // Endpoints effectively the same size: no fraction is recoverable.
        #expect(ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 100, height: 100),
            start: CGSize(width: 100, height: 100.5),
            end: CGSize(width: 100, height: 100)
        ) == nil)
    }

    /// Round trip, swept: pose the card at a fraction, recover the fraction
    /// from the posed size, and land back on the number you left from.
    @Test func caughtFractionRoundTripsThroughThePoseArithmetic() {
        var random = SeededRandom(seed: 0x0F0F)
        for _ in 0..<300 {
            let start = CGSize(
                width: CGFloat(random.next(in: 60...500)),
                height: CGFloat(random.next(in: 60...900))
            )
            let end = CGSize(
                width: CGFloat(random.next(in: 60...500)),
                height: CGFloat(random.next(in: 60...900))
            )
            guard abs(end.height - start.height) > 1 || abs(end.width - start.width) > 1 else {
                continue
            }
            let fraction = CGFloat(random.nextUnit())
            let posed = CGSize(
                width: start.width + (end.width - start.width) * fraction,
                height: start.height + (end.height - start.height) * fraction
            )
            let recovered = ZoomFlightGrabHandoff.caughtFraction(
                presented: posed, start: start, end: end
            )
            #expect(abs((recovered ?? -1) - fraction) < 0.001,
                    "round trip lost the fraction: \(fraction) -> \(String(describing: recovered))")
        }
    }
}
