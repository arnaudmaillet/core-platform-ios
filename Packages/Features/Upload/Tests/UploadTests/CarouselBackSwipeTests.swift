import Testing
import UIKit
@testable import Upload

/// When a carousel gives a sideways drag back to the stack.
///
/// ⚠️ **WHAT THESE TESTS CANNOT SAY.** No unit test can begin the stack's own
/// back-swipe, so none of this proves the screen pops — an earlier revision of
/// this work had 89 green tests around a rule wired to a recogniser the gesture
/// never reaches. The proof is an injected drag on a device; these fix the
/// decision itself so a regression in it fails here first.
@MainActor
struct CarouselBackSwipeTests {
    private static let right = CGPoint(x: 60, y: 2)
    private static let left = CGPoint(x: -60, y: 2)
    /// Leaning right, but it is a page scroll.
    private static let mostlyDown = CGPoint(x: 12, y: 80)

    // MARK: - The rule

    @Test func aCarouselAtItsFirstItemGivesARightwardDragToTheStack() {
        #expect(CarouselBackSwipe.yields(translation: Self.right, isAtLeadingEdge: true, startedNearLeadingEdge: true))
    }

    @Test func aCarouselWithSomethingToItsLeftKeepsIt() {
        #expect(CarouselBackSwipe.yields(translation: Self.right, isAtLeadingEdge: false, startedNearLeadingEdge: true) == false)
    }

    @Test func aLeftwardDragIsAlwaysTheCarousels() {
        #expect(CarouselBackSwipe.yields(translation: Self.left, isAtLeadingEdge: true, startedNearLeadingEdge: true) == false)
    }

    /// ⚠️ THE ONE THAT PROTECTS THE FINALISATION SCREEN. Its strip lives inside a
    /// vertical list, so a drag that is mostly downward but leans right is
    /// someone scrolling the page — handing that to the stack would make the
    /// screen leave under them.
    @Test func aMostlyVerticalDragIsNeverABackSwipe() {
        #expect(CarouselBackSwipe.yields(translation: Self.mostlyDown, isAtLeadingEdge: true, startedNearLeadingEdge: true) == false)
    }

    @Test func aPurelyVerticalDragIsNotOneEither() {
        #expect(
            CarouselBackSwipe.yields(translation: CGPoint(x: 0, y: 90), isAtLeadingEdge: true, startedNearLeadingEdge: true) == false
        )
    }

    // MARK: - Where the finger started

    /// ⚠️ **THE BRANCH THIS SUITE ALMOST SHIPPED UNCOVERED.** Every other case
    /// here passes `startedNearLeadingEdge: true`, so deleting that guard would
    /// leave the suite green. It exists because the stack only accepts a
    /// back-swipe begun at the window's edge: a carousel that stood aside for a
    /// drag starting mid-screen would hand the touch to a gesture that then
    /// refuses it, and the drag would neither pop nor rubber-band.
    @Test func aCarouselKeepsADragThatDidNotStartAtTheWindowsEdge() {
        #expect(
            CarouselBackSwipe.yields(
                translation: Self.right, isAtLeadingEdge: true, startedNearLeadingEdge: false
            ) == false,
            "at its first item, but the finger began mid-screen: the carousel keeps it"
        )
    }

    /// Both conditions are required, not either.
    @Test func startingAtTheEdgeIsNotEnoughIfTheCarouselCanStillScrollBack() {
        #expect(
            CarouselBackSwipe.yields(
                translation: Self.right, isAtLeadingEdge: false, startedNearLeadingEdge: true
            ) == false
        )
    }

    // MARK: - Where the leading edge actually is

    @Test func aPlainScrollerAtZeroIsAtItsLeadingEdge() {
        let scroller = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 208))
        scroller.contentSize = CGSize(width: 1600, height: 208)

        #expect(CarouselBackSwipe.isAtLeadingEdge(scroller))
    }

    /// ⚠️ **THE LEADING EDGE IS NOT ZERO WHEN THE CONTENT IS CENTRED.** The
    /// finalisation strip computes a `contentInset` to centre its thumbnails, so
    /// at rest it sits at minus that inset. Judging it against zero would read
    /// every resting strip as scrolled and it would never yield.
    @Test func aCentredStripAtRestIsAtItsLeadingEdgeToo() {
        let scroller = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 208))
        scroller.contentSize = CGSize(width: 1600, height: 208)
        scroller.contentInset.left = 16
        scroller.contentOffset.x = -16

        #expect(CarouselBackSwipe.isAtLeadingEdge(scroller))
    }

    @Test func aStripThatHasTravelledIsNot() {
        let scroller = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 208))
        scroller.contentSize = CGSize(width: 1600, height: 208)
        scroller.contentInset.left = 16
        scroller.contentOffset.x = 0

        #expect(
            CarouselBackSwipe.isAtLeadingEdge(scroller) == false,
            "zero offset against a 16pt inset means it has travelled 16pt"
        )
    }
}
