import CoreGraphics
import Testing
@testable import DesignSystem

/// When a screen's selector changes homes.
///
/// The bug this answers only appears at speed: flicked hard past the dock line,
/// the selector doubled and flashed — both copies legible at once, the inline
/// one still travelling while it faded. Every assertion here is a speed the
/// screenshot of a settled screen cannot express.
///
/// Pinned here rather than beside either host because two screens share the
/// arithmetic and have to feel identical running it; a per-screen copy of these
/// assertions would let their numbers drift apart while both suites stayed green.
@MainActor
struct DockThresholdTests {
    private let line: CGFloat = 400

    // MARK: - The line itself

    /// Docking happens AT the line, with no slack. A moment longer and the
    /// inline selector is behind the chrome it was about to hand over to.
    @Test(arguments: [CGFloat(400), 401, 900])
    func reachingTheLineDocks(travelled: CGFloat) {
        #expect(DockThreshold.isDocked(
            travelled: travelled, dockLine: line, step: 4, wasDocked: false
        ))
    }

    @Test(arguments: [CGFloat(0), 200, 399])
    func shortOfTheLineDoesNotDock(travelled: CGFloat) {
        #expect(DockThreshold.isDocked(
            travelled: travelled, dockLine: line, step: 4, wasDocked: false
        ) == false)
    }

    /// Coming back is what gets slack: a docked selector holds until the header
    /// is clear of the line, so a finger resting on it does not flicker.
    @Test func aDockedSelectorHoldsJustBelowTheLine() {
        #expect(DockThreshold.isDocked(
            travelled: 395, dockLine: line, step: 2, wasDocked: true
        ))
    }

    @Test func aDockedSelectorLetsGoWellBelowTheLine() {
        #expect(DockThreshold.isDocked(
            travelled: 300, dockLine: line, step: 2, wasDocked: true
        ) == false)
    }

    // MARK: - Speed

    /// ⚠️ **The band has to out-measure a single step, or it is not a band at
    /// the speed that needs one.** A hard flick moves the header further
    /// between two frames than the resting band is wide, so a fixed band lets
    /// deceleration overshoot cross back and forth and the selector flaps once
    /// per frame.
    @Test func aFastStepWidensTheBandPastItself() {
        // 60pt in one frame, landing 50pt below the line: a fixed 12pt band
        // would undock here, and the next frame's overshoot would re-dock.
        #expect(DockThreshold.isDocked(
            travelled: 350, dockLine: line, step: -60, wasDocked: true
        ))
    }

    /// The widening follows the step's SIZE, not its sign — the header
    /// overshoots in both directions.
    @Test func theBandDoesNotCareWhichWayTheHeaderMoved() {
        let up = DockThreshold.isDocked(
            travelled: 350, dockLine: line, step: 60, wasDocked: true
        )
        let down = DockThreshold.isDocked(
            travelled: 350, dockLine: line, step: -60, wasDocked: true
        )
        #expect(up == down)
    }

    /// Fast is not infinite: a flick that genuinely leaves the region still
    /// undocks, or the selector would stick in the navigation bar over a header
    /// scrolled back to its top.
    @Test func aFlickAllTheWayBackStillUndocks() {
        #expect(DockThreshold.isDocked(
            travelled: 0, dockLine: line, step: -120, wasDocked: true
        ) == false)
    }

    /// At a resting speed the band is the resting band — the widening is for
    /// flicks, and must not quietly become the everyday behaviour.
    @Test func aSlowStepLeavesTheRestingBandAlone() {
        #expect(DockThreshold.isDocked(
            travelled: 385, dockLine: line, step: 1, wasDocked: true
        ) == false)
        #expect(DockThreshold.isDocked(
            travelled: 392, dockLine: line, step: 1, wasDocked: true
        ))
    }

    // MARK: - Whether to animate it

    /// Scrolling gets the crossfade: this is the speed the hand-over was
    /// designed at and looks best at.
    @Test(arguments: [CGFloat(0), 1, 6, 10, 13])
    func aReadableScrollAnimatesTheHandover(step: CGFloat) {
        #expect(DockThreshold.isAnimated(step: step))
    }

    /// ⚠️ A flick does NOT. The crossfade shows both selectors at once by
    /// definition, and at this speed the inline one is still travelling while it
    /// fades — so the two read as separate objects sliding apart rather than as
    /// one control changing places. Measured at four consecutive frames with
    /// both fully legible.
    @Test(arguments: [CGFloat(14), 20, 60, 200])
    func aFlickSwapsWithoutAnimating(step: CGFloat) {
        #expect(DockThreshold.isAnimated(step: step) == false)
    }

    /// Speed, not direction — a hard flick back up doubles the selector exactly
    /// as a hard flick down does.
    @Test(arguments: [CGFloat(-14), -20, -60, -200])
    func aFlickUpwardsAlsoSwapsWithoutAnimating(step: CGFloat) {
        #expect(DockThreshold.isAnimated(step: step) == false)
    }

    // MARK: - Fading the identity block

    /// Through most of its travel the block is what the viewer came to read, so
    /// it is at full strength.
    @Test(arguments: [CGFloat(-200), 0, 100, 300, 310])
    func theIdentityBlockIsWhollyVisibleWellAboveTheLine(travelled: CGFloat) {
        #expect(DockThreshold.identityAlpha(travelled: travelled, dockLine: line) == 1)
    }

    /// ⚠️ It reaches zero exactly AT the line, and that is load-bearing rather
    /// than tidy. The host stops being hidden on docking, so the fade is the
    /// only thing keeping the block — the profile's bio, where this was caught —
    /// from drawing through a transparent navigation bar and over the status
    /// bar. A fade that finished late would put it there; one that finished
    /// early would blink.
    @Test func theIdentityBlockIsGoneByTheDockLine() {
        #expect(DockThreshold.identityAlpha(travelled: line, dockLine: line) == 0)
    }

    @Test(arguments: [CGFloat(400), 500, 5_000])
    func theIdentityBlockStaysGonePastTheLine(travelled: CGFloat) {
        #expect(DockThreshold.identityAlpha(travelled: travelled, dockLine: line) == 0)
    }

    /// In between it is neither, and monotonically so — a fade that reversed
    /// anywhere in its window would read as a flicker.
    @Test func theFadeOnlyEverDarkens() {
        let samples = stride(from: CGFloat(300), through: 400, by: 5).map {
            DockThreshold.identityAlpha(travelled: $0, dockLine: line)
        }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
        // And it genuinely passes through the middle rather than stepping.
        #expect(samples.contains { $0 > 0.2 && $0 < 0.8 })
    }

    /// Halfway through the window is halfway faded: the ramp is linear, so the
    /// block's visibility tracks the finger rather than easing away from it.
    @Test func halfwayThroughTheWindowIsHalfFaded() {
        let alpha = DockThreshold.identityAlpha(
            travelled: line - DockThreshold.identityFadeDistance / 2, dockLine: line
        )
        #expect(abs(alpha - 0.5) < 0.001)
    }

    /// ⚠️ Before the first layout pass there is no travel to speak of, and a
    /// window measured against zero would make the block invisible on arrival.
    @Test func withoutAHeaderToTravelTheBlockIsVisible() {
        #expect(DockThreshold.identityAlpha(travelled: 0, dockLine: 0) == 1)
    }
}
