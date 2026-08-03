import CoreGraphics
@testable import CoreNavigation
import Testing

/// The mid-air catch is a state machine plus two channels, and both halves
/// live in `ZoomFlightGrabHandoff` precisely so they can be pinned here
/// without a live transition: the phases are a one-way street (frozen at most
/// once, caught at most once, decided at most once), the scrub is measured
/// from the catch point, and the free channel's arithmetic is what makes the
/// card follow the finger 1:1 instead of crawling along the baked rail.
struct ZoomFlightGrabHandoffTests {
    private func presentCatch(span: CGFloat = 1000) -> ZoomFlightGrabHandoff {
        ZoomFlightGrabHandoff(advancesOnDownwardDrag: false, span: span)
    }

    private func dismissCatch(span: CGFloat = 1000) -> ZoomFlightGrabHandoff {
        ZoomFlightGrabHandoff(advancesOnDownwardDrag: true, span: span)
    }

    // MARK: - State transitions

    @Test func aTouchFreezesOnlyAnUntouchedFlight() {
        var handoff = presentCatch()
        let first = handoff.touchDown()
        #expect(first == .pauseFlight)
        #expect(handoff.phase == .frozen)
        // A repeat (or a second finger) must not re-freeze machinery another
        // phase already owns.
        let repeated = handoff.touchDown()
        #expect(repeated == nil)
    }

    @Test func aTapHoldResumesTowardTheEndAndSpendsTheHandoff() {
        var handoff = presentCatch()
        _ = handoff.touchDown()
        let lift = handoff.touchUp()
        #expect(lift == .resumeTowardEnd)
        #expect(handoff.phase == .decided)
        // Spent: every further event is refused.
        let lateTouch = handoff.touchDown()
        let lateGrab = handoff.grabBegan(atFraction: 0.5)
        let lateRelease = handoff.released(verticalTranslation: 0, verticalVelocity: 0)
        #expect(lateTouch == nil)
        #expect(!lateGrab)
        #expect(lateRelease == nil)
    }

    @Test func aGrabMayBeginFromFlightOrFromFreeze() {
        // Directly — the pan paused the flight itself...
        var direct = presentCatch()
        let began = direct.grabBegan(atFraction: 0.4)
        #expect(began)
        #expect(direct.phase == .grabbing)
        // ...or after the touch catcher froze it first.
        var afterTouch = presentCatch()
        _ = afterTouch.touchDown()
        let beganAfterFreeze = afterTouch.grabBegan(atFraction: 0.4)
        #expect(beganAfterFreeze)
        #expect(afterTouch.phase == .grabbing)
    }

    @Test func aFlightIsCaughtAtMostOnce() {
        var handoff = presentCatch()
        let first = handoff.grabBegan(atFraction: 0.4)
        let second = handoff.grabBegan(atFraction: 0.6)
        #expect(first)
        #expect(!second)
        // The catch point survives the refused second claim.
        #expect(handoff.grabbedAt == 0.4)
    }

    @Test func touchUpDuringAGrabIsThePansToDecide() {
        var handoff = presentCatch()
        _ = handoff.touchDown()
        _ = handoff.grabBegan(atFraction: 0.4)
        // The zero-duration press also ends when the finger lifts mid-grab;
        // the release decision belongs to the pan alone.
        let lift = handoff.touchUp()
        #expect(lift == nil)
        #expect(handoff.phase == .grabbing)
    }

    @Test func releaseIsTerminal() {
        var handoff = presentCatch()
        _ = handoff.grabBegan(atFraction: 0.5)
        let first = handoff.released(verticalTranslation: 0, verticalVelocity: 0)
        let second = handoff.released(verticalTranslation: 0, verticalVelocity: 0)
        #expect(first != nil)
        #expect(handoff.phase == .decided)
        #expect(second == nil)
    }

    // MARK: - Scrub channel

    @Test func downwardDragReversesAPresentAndAdvancesADismissal() {
        var present = presentCatch()
        _ = present.grabBegan(atFraction: 0.5)
        #expect(present.fraction(forVerticalTranslation: 200) == 0.3)

        var dismiss = dismissCatch()
        _ = dismiss.grabBegan(atFraction: 0.5)
        #expect(dismiss.fraction(forVerticalTranslation: 200) == 0.7)
    }

    @Test func theScrubIsMeasuredFromTheCatchAndClamped() {
        var handoff = presentCatch()
        _ = handoff.grabBegan(atFraction: 0.9)
        // No travel → exactly where it was caught; grabbing a half-flown card
        // must not snap it anywhere.
        #expect(handoff.fraction(forVerticalTranslation: 0) == 0.9)
        // Up past the end and down past the start both clamp.
        #expect(handoff.fraction(forVerticalTranslation: -200) == 1)
        #expect(handoff.fraction(forVerticalTranslation: 2000) == 0)
    }

    // MARK: - Free channel

    @Test func nearTheCatchTheCardFollowsTheFingerOneToOne() {
        let handoff = presentCatch()
        // The rail spent 6pt of a 10pt drag; the offset carries the rest, so
        // rail + offset ≈ the finger's translation — which is what "follows
        // the finger" means.
        let offset = handoff.freeOffset(
            translation: CGPoint(x: 8, y: 10), railDelta: CGPoint(x: 0, y: 6)
        )
        #expect(abs(offset.x - 8) < 0.5)
        #expect(abs(offset.y - 4) < 0.2)
    }

    @Test func theFreeChannelRubberBandsAtItsCapsAndKeepsTheSign() {
        let handoff = presentCatch()
        let offset = handoff.freeOffset(
            translation: CGPoint(x: 10_000, y: -10_000), railDelta: .zero
        )
        #expect(offset.x > 0)
        #expect(offset.x < handoff.horizontalDriftLimit)
        #expect(offset.y < 0)
        #expect(offset.y > -handoff.verticalDriftLimit)
    }

    // MARK: - Release contract

    @Test func aCaughtPresentReleasedPastTheThresholdKeepsOpening() {
        var handoff = presentCatch()
        _ = handoff.grabBegan(atFraction: 0.5)
        let release = handoff.released(verticalTranslation: 0, verticalVelocity: 0)
        #expect(release?.completes == true)
    }

    @Test func aCaughtPresentDraggedBelowTheThresholdReverses() {
        var handoff = presentCatch()
        _ = handoff.grabBegan(atFraction: 0.5)
        // 300pt down on a 1000pt span → progress 0.2, under the shared 0.35.
        let release = handoff.released(verticalTranslation: 300, verticalVelocity: 0)
        #expect(release?.completes == false)
    }

    @Test func aDownwardFlickReversesAPresentHoweverFarItHadFlown() {
        var handoff = presentCatch()
        _ = handoff.grabBegan(atFraction: 0.9)
        // The hand's speed at release outranks where the machine happened to
        // be — this is where the caught contract departs from the
        // grab-from-rest one, whose progress term would have won here.
        let release = handoff.released(verticalTranslation: 40, verticalVelocity: 1200)
        #expect(release?.completes == false)
    }

    @Test func anUpwardFlickCompletesAPresentFromAlmostNowhere() {
        var handoff = presentCatch()
        _ = handoff.grabBegan(atFraction: 0.1)
        let release = handoff.released(verticalTranslation: -20, verticalVelocity: -1200)
        #expect(release?.completes == true)
    }

    @Test func aDownwardFlickCompletesACaughtDismissal() {
        var handoff = dismissCatch()
        _ = handoff.grabBegan(atFraction: 0.1)
        // On the dismiss leg down IS toward the end, so the same flick that
        // reverses a present sends a dismissal home.
        let release = handoff.released(verticalTranslation: 40, verticalVelocity: 1200)
        #expect(release?.completes == true)
    }

    // MARK: - Caught fraction

    /// The percent driver's synced fraction is time-based and wrong for a
    /// spring (measured as 0.00 on a half-flown flight — the size snap on
    /// catch). The screen's own fraction is recovered from the card's
    /// presentation size instead; these pin that solve.
    @Test func theCaughtFractionIsRecoveredFromThePresentedSize() {
        // Present leg: tile 120x80 → page 400x880. Halfway in size IS the
        // scalar the whole pose rides on.
        let half = ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 260, height: 480),
            start: CGSize(width: 120, height: 80),
            end: CGSize(width: 400, height: 880)
        )
        #expect(half != nil)
        #expect(abs((half ?? -1) - 0.5) < 0.001)
        // At an endpoint, exactly that endpoint.
        #expect(ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 120, height: 80),
            start: CGSize(width: 120, height: 80),
            end: CGSize(width: 400, height: 880)
        ) == 0)
    }

    @Test func theCaughtFractionSolvesOnTheLongerAxisAndHandlesBothLegs() {
        // Wide tile: width travels further than height, so width decides.
        let wide = ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 300, height: 862),
            start: CGSize(width: 400, height: 874),
            end: CGSize(width: 0, height: 826)
        )
        #expect(abs((wide ?? -1) - 0.25) < 0.001)
        // Dismiss leg runs page → tile: a card near the tile reads near 1.
        let landing = ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 130, height: 100),
            start: CGSize(width: 400, height: 880),
            end: CGSize(width: 120, height: 80)
        )
        #expect((landing ?? 0) > 0.95)
    }

    @Test func theCaughtFractionIsClampedAndRefusesDegenerateEndpoints() {
        // Overshoot past the page (spring bounce) clamps rather than escapes.
        #expect(ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 410, height: 900),
            start: CGSize(width: 120, height: 80),
            end: CGSize(width: 400, height: 880)
        ) == 1)
        // Same-sized endpoints: no fraction is recoverable — nil, so the
        // caller keeps the synced value instead of dividing by nothing.
        #expect(ZoomFlightGrabHandoff.caughtFraction(
            presented: CGSize(width: 200, height: 200),
            start: CGSize(width: 200, height: 200),
            end: CGSize(width: 200, height: 200)
        ) == nil)
    }

    // MARK: - Continuation spring

    @Test func theContinuationVelocityPointsAtTheOutcome() {
        // Present leg, flicked upward, completing: the hand moves toward the
        // end, so the unit velocity is positive (toward the target).
        let toward = ZoomFlightGrabHandoff.continuationVelocity(
            rawVerticalVelocity: -500, atProgress: 0.5,
            towardEnd: true, direction: -1, span: 1000
        )
        #expect(toward > 0)
        // The same hand when the outcome is the START: the target flips, so
        // the sign flips with it.
        let away = ZoomFlightGrabHandoff.continuationVelocity(
            rawVerticalVelocity: -500, atProgress: 0.5,
            towardEnd: false, direction: -1, span: 1000
        )
        #expect(away < 0)
    }

    @Test func theContinuationVelocityIsClampedAgainstWildFlicks() {
        let clamped = ZoomFlightGrabHandoff.continuationVelocity(
            rawVerticalVelocity: -100_000, atProgress: 0.99,
            towardEnd: true, direction: -1, span: 1000
        )
        #expect(clamped == 3)
    }
}

/// The caught-flight release contract is deliberately NOT
/// `shouldCompleteDismissal`: a caught flight's progress is mostly the
/// animation's, so a decisive flick must win in either direction. These pin
/// the asymmetry so the two contracts cannot silently converge.
struct CaughtReleaseContractTests {
    @Test func aDecisiveFlickWinsInEitherDirection() {
        #expect(ZoomTransitionGeometry.caughtReleaseCompletes(
            progress: 0.05, velocityTowardEnd: 900
        ))
        #expect(!ZoomTransitionGeometry.caughtReleaseCompletes(
            progress: 0.95, velocityTowardEnd: -900
        ))
    }

    @Test func belowFlickSpeedTheSharedThresholdDecides() {
        #expect(ZoomTransitionGeometry.caughtReleaseCompletes(
            progress: 0.35, velocityTowardEnd: 0
        ))
        #expect(!ZoomTransitionGeometry.caughtReleaseCompletes(
            progress: 0.34, velocityTowardEnd: 0
        ))
        // A sub-flick drift does not override the threshold either way.
        #expect(ZoomTransitionGeometry.caughtReleaseCompletes(
            progress: 0.5, velocityTowardEnd: -400
        ))
        #expect(!ZoomTransitionGeometry.caughtReleaseCompletes(
            progress: 0.2, velocityTowardEnd: 400
        ))
    }
}
