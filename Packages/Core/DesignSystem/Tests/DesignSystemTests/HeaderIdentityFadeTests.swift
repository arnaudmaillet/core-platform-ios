import CoreGraphics
import Testing
@testable import DesignSystem

/// How faded the identity block is at a given header position.
///
/// ⚠️ **THE DOCKING ASSERTIONS ARE GONE, AND SO IS WHAT THEY TESTED.** This
/// suite used to pin a speed-widened docking band and a crossfade speed limit,
/// both of which existed for one symptom: a selector that doubled and flashed
/// when the header was flicked hard past its dock line. Nothing docks any more
/// — every selector sits at the foot of the screen for its screen's whole life
/// — so there is no second copy to cross-fade and no line to cross. Tests kept
/// for a mechanism that has been deleted assert the behaviour of nothing.
///
/// The fade is still real, because the header still travels.
@MainActor
struct HeaderIdentityFadeTests {
    private let line: CGFloat = 400

    /// Through most of its travel the block is what the viewer came to read, so
    /// it is at full strength.
    @Test(arguments: [CGFloat(-200), 0, 100, 300, 310])
    func theIdentityBlockIsWhollyVisibleWellAboveTheLine(travelled: CGFloat) {
        #expect(HeaderIdentityFade.alpha(travelled: travelled, dockLine: line) == 1)
    }

    /// ⚠️ It reaches zero exactly AT the line, and that is load-bearing rather
    /// than tidy. The host stops being hidden on docking, so the fade is the
    /// only thing keeping the block — the profile's bio, where this was caught —
    /// from drawing through a transparent navigation bar and over the status
    /// bar. A fade that finished late would put it there; one that finished
    /// early would blink.
    @Test func theIdentityBlockIsGoneByTheDockLine() {
        #expect(HeaderIdentityFade.alpha(travelled: line, dockLine: line) == 0)
    }

    @Test(arguments: [CGFloat(400), 500, 5_000])
    func theIdentityBlockStaysGonePastTheLine(travelled: CGFloat) {
        #expect(HeaderIdentityFade.alpha(travelled: travelled, dockLine: line) == 0)
    }

    /// In between it is neither, and monotonically so — a fade that reversed
    /// anywhere in its window would read as a flicker.
    @Test func theFadeOnlyEverDarkens() {
        let samples = stride(from: CGFloat(300), through: 400, by: 5).map {
            HeaderIdentityFade.alpha(travelled: $0, dockLine: line)
        }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
        // And it genuinely passes through the middle rather than stepping.
        #expect(samples.contains { $0 > 0.2 && $0 < 0.8 })
    }

    /// Halfway through the window is halfway faded: the ramp is linear, so the
    /// block's visibility tracks the finger rather than easing away from it.
    @Test func halfwayThroughTheWindowIsHalfFaded() {
        let alpha = HeaderIdentityFade.alpha(
            travelled: line - HeaderIdentityFade.distance / 2, dockLine: line
        )
        #expect(abs(alpha - 0.5) < 0.001)
    }

    /// ⚠️ Before the first layout pass there is no travel to speak of, and a
    /// window measured against zero would make the block invisible on arrival.
    @Test func withoutAHeaderToTravelTheBlockIsVisible() {
        #expect(HeaderIdentityFade.alpha(travelled: 0, dockLine: 0) == 1)
    }
}
