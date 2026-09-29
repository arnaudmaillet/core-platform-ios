import CoreGraphics
import Testing
@testable import Feed

/// THE BAR PILLS FOLLOW THE FINGER.
///
/// `BarPillScrub` is the whole contract of the scroll-driven pill blur (asked
/// 2026-09-30): sharp until the page being left is 30% off screen, fully
/// blurred while the two pages split the screen, sharp again once the incoming
/// page covers 70% — and the content changes hands at the midpoint, with
/// enough hysteresis that a held finger cannot make it flicker.
struct BarPillScrubTests {
    // MARK: - The blur curve

    @Test func sharpUntilThirtyPercentAndFromSeventy() {
        for coverage in [0, 0.1, 0.25, 0.3, 0.7, 0.8, 1] as [CGFloat] {
            #expect(BarPillScrub.blur(coverage: coverage) == 0, "blurred at \(coverage)")
        }
    }

    @Test func fullyBlurredAcrossTheMidpoint() {
        for coverage in [0.485, 0.49, 0.5, 0.51, 0.515] as [CGFloat] {
            #expect(BarPillScrub.blur(coverage: coverage) == 1, "not fully blurred at \(coverage)")
        }
    }

    /// Interpolated with the scroll: every step toward the midpoint blurs
    /// more, every step past it sharpens.
    @Test func risesThenFallsWithTheScroll() {
        let rising = stride(from: 0.31, through: 0.48, by: 0.01).map { BarPillScrub.blur(coverage: $0) }
        let falling = stride(from: 0.52, through: 0.69, by: 0.01).map { BarPillScrub.blur(coverage: $0) }
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $0 < $1 })
        #expect(zip(falling, falling.dropFirst()).allSatisfy { $0 > $1 })
        #expect(rising.allSatisfy { $0 > 0 && $0 <= 1 })
        #expect(falling.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    /// Scrolling UP is the same curve mirrored: the page coming in from above
    /// covers `1 - p`.
    @Test func symmetricForBothDirections() {
        for coverage in stride(from: 0, through: 1, by: 0.05) as StrideThrough<CGFloat> {
            #expect(abs(BarPillScrub.blur(coverage: coverage) - BarPillScrub.blur(coverage: 1 - coverage)) < 1e-9)
        }
    }

    // MARK: - The pair

    @Test func aFrameIsThePairTheViewportStraddles() throws {
        let frame = try #require(BarPillScrub.frame(position: 2.4, itemCount: 5))
        #expect(frame.upper == 2)
        #expect(abs(frame.blur - BarPillScrub.blur(coverage: 0.4)) < 1e-6)
    }

    /// A bounce above the first page or into the paging footer below the last
    /// has no page to change to: nothing blurs.
    @Test func noFramePastEitherEnd() {
        #expect(BarPillScrub.frame(position: -0.5, itemCount: 5) == nil)
        #expect(BarPillScrub.frame(position: 4.5, itemCount: 5) == nil)
        #expect(BarPillScrub.frame(position: 0.5, itemCount: 1) == nil)
        #expect(BarPillScrub.frame(position: .nan, itemCount: 5) == nil)
    }

    @Test func restingOnAPageIsSharp() {
        #expect(BarPillScrub.frame(position: 3, itemCount: 5)?.blur == 0)
    }

    // MARK: - The swap

    /// Nothing has settled: the scroll has no content to swap from.
    @Test func noSwapBeforeASettle() {
        var scrub = BarPillScrub()
        #expect(scrub.update(position: 0.9, itemCount: 5) == nil)
    }

    /// The content changes once the incoming page is past half — at the
    /// hysteresis, inside the full blur.
    @Test func swapsPastTheMidpoint() {
        var scrub = BarPillScrub()
        scrub.settle(at: 0)
        #expect(scrub.update(position: 0.4, itemCount: 5) == nil)
        #expect(scrub.update(position: 0.5, itemCount: 5) == nil)
        #expect(scrub.update(position: 0.51, itemCount: 5) == nil)
        #expect(scrub.update(position: 0.53, itemCount: 5) == 1)
        #expect(BarPillScrub.blur(coverage: 0.52 + 1e-6) > 0.99, "the swap point is not under the full blur")
        #expect(scrub.update(position: 0.8, itemCount: 5) == nil, "swapped twice for one page")
        #expect(scrub.shownIndex == 1)
    }

    /// A drag back below half swaps back — once past the band, not at the
    /// first frame under 0.5.
    @Test func aDragBackSwapsBack() {
        var scrub = BarPillScrub()
        scrub.settle(at: 0)
        #expect(scrub.update(position: 0.6, itemCount: 5) == 1)
        #expect(scrub.update(position: 0.49, itemCount: 5) == nil)
        #expect(scrub.update(position: 0.47, itemCount: 5) == 0)
        #expect(scrub.shownIndex == 0)
    }

    /// A finger held at the midpoint, jittering by a point either way, never
    /// swaps the pills back and forth.
    @Test func aHeldFingerDoesNotFlicker() {
        var scrub = BarPillScrub()
        scrub.settle(at: 0)
        _ = scrub.update(position: 0.53, itemCount: 5)
        var swaps = 0
        for jitter in [0.5, 0.49, 0.51, 0.495, 0.505, 0.485, 0.515, 0.5] as [CGFloat] {
            if scrub.update(position: jitter, itemCount: 5) != nil { swaps += 1 }
        }
        #expect(swaps == 0)
    }

    /// Scrolling UP swaps to the page above past ITS midpoint.
    @Test func scrollingUpSwapsToThePageAbove() {
        var scrub = BarPillScrub()
        scrub.settle(at: 3)
        #expect(scrub.update(position: 2.6, itemCount: 5) == nil)
        #expect(scrub.update(position: 2.47, itemCount: 5) == 2)
    }

    /// A fling that crossed several pages in a frame swaps straight to the
    /// page covering the screen now.
    @Test func aJumpSwapsToTheNearestPage() {
        var scrub = BarPillScrub()
        scrub.settle(at: 0)
        #expect(scrub.update(position: 2.8, itemCount: 5) == 3)
    }

    /// Overscrolled past the last page (the paging footer), the last page
    /// stays.
    @Test func overscrollKeepsTheLastPage() {
        var scrub = BarPillScrub()
        scrub.settle(at: 4)
        #expect(scrub.update(position: 4.7, itemCount: 5) == nil)
        scrub.settle(at: 0)
        #expect(scrub.update(position: -0.7, itemCount: 5) == nil)
    }
}
