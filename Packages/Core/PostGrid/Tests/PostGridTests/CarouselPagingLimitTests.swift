import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// One gesture moves one page, and the dots stay small until touched.
@MainActor
struct CarouselPagingLimitTests {
    private func carousel(pages count: Int) -> MediaCarouselView {
        let view = MediaCarouselView(
            style: .card, frame: CGRect(x: 0, y: 0, width: 358, height: 240)
        )
        view.configure(
            with: (0..<count).map {
                GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://t/\($0)"))
            },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        view.layoutIfNeeded()
        return view
    }

    /// ⚠️ MOMENTUM DECIDES HOW FAST, NEVER HOW FAR.
    ///
    /// The snap read the PROJECTED offset, which on a hard flick is three or
    /// four pages away — a scroll, not paging. The viewer asked for the next
    /// photograph and got a blur and a stranger. A violent swipe and a careful
    /// one must land on the same page.
    @Test func aViolentFlickStillMovesOnlyOnePage() {
        let view = carousel(pages: 12)
        view.setPage(4, animated: false)
        let scrollView = UIScrollView()
        scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: 4), y: 0)

        var target = CGPoint(x: view.debugOffset(forPage: 11), y: 0)
        withUnsafeMutablePointer(to: &target) {
            view.scrollViewWillEndDragging(
                scrollView, withVelocity: CGPoint(x: 9, y: 0), targetContentOffset: $0
            )
        }

        #expect(target.x == view.debugOffset(forPage: 5))
    }

    /// And the same in the other direction, asserted beside it: a rule applied
    /// to one sign only is half a rule.
    @Test func aViolentFlickBackwardsAlsoMovesOnlyOnePage() {
        let view = carousel(pages: 12)
        view.setPage(6, animated: false)
        let scrollView = UIScrollView()
        scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: 6), y: 0)

        var target = CGPoint(x: view.debugOffset(forPage: 0), y: 0)
        withUnsafeMutablePointer(to: &target) {
            view.scrollViewWillEndDragging(
                scrollView, withVelocity: CGPoint(x: -9, y: 0), targetContentOffset: $0
            )
        }

        #expect(target.x == view.debugOffset(forPage: 5))
    }

    /// A gentle drag that lands short still settles where it was let go, so the
    /// clamp has not turned every gesture into a page change.
    @Test func aDragThatGoesNowhereStaysPut() {
        let view = carousel(pages: 12)
        view.setPage(4, animated: false)
        let scrollView = UIScrollView()
        scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: 4), y: 0)

        var target = CGPoint(x: view.debugOffset(forPage: 4), y: 0)
        withUnsafeMutablePointer(to: &target) {
            view.scrollViewWillEndDragging(
                scrollView, withVelocity: .zero, targetContentOffset: $0
            )
        }

        #expect(target.x == view.debugOffset(forPage: 4))
    }

    // MARK: - The indicator's gesture

    /// ⚠️ TOUCHING IT ASKS FOR NOTHING; ONLY DRAGGING DOES.
    ///
    /// A press used to select the page under the finger, which put two meanings
    /// on one touch: a tap changed the page, and a tap that became a drag
    /// changed it twice — once to wherever it landed and again to wherever it
    /// went. The dots are narrow and sit between two counters, so the first of
    /// those was as often a miss as an instruction.
    @Test func aPressAloneRequestsNoPage() {
        let indicator = MediaPageIndicatorView()
        indicator.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
        indicator.configure(count: 12, current: 0)
        var requested: [Int] = []
        indicator.onPageRequested = { requested.append($0) }

        indicator.debugScrub(.began, atX: 100)

        #expect(requested.isEmpty)
    }

    /// And dragging does, at the page under the finger — asserted beside its
    /// opposite, because a gesture that asks for nothing at all would satisfy
    /// the test above.
    @Test func draggingRequestsThePageUnderTheFinger() {
        let indicator = MediaPageIndicatorView()
        indicator.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
        indicator.configure(count: 12, current: 0)
        var requested: [Int] = []
        indicator.onPageRequested = { requested.append($0) }

        indicator.debugScrub(.began, atX: 10)
        indicator.debugScrub(.changed, atX: 110)

        #expect(requested.count == 1)
        #expect((requested.first ?? 0) > 6)
    }

    // MARK: - The dots

    /// ⚠️ FIVE, at any length, at rest and under a finger alike.
    ///
    /// The chip used to grow while being scrubbed, which moved the dots the
    /// finger had just landed on — the scrub began with a jump and selected a
    /// page that had not been under the thumb a frame earlier. A control whose
    /// targets move when you touch it cannot be aimed. So the width is fixed
    /// and the WINDOW travels instead.
    @Test func aLongGalleryDrawsAFixedWindowOfFive() {
        let dots = PageDotsView()
        dots.configure(count: 12)

        #expect(dots.intrinsicContentSize.width
                == PageDotsView.chipWidth(forDots: PageDotsView.maximumVisibleDots))
    }

    /// A gallery under the window asks for exactly what it has — the window is a
    /// ceiling, not a padding, or a dot would sit under a page that is not there.
    @Test func aShortGalleryAsksForItsOwnDots() {
        let dots = PageDotsView()
        dots.configure(count: 3)

        #expect(dots.intrinsicContentSize.width == PageDotsView.chipWidth(forDots: 3))
    }

    /// ⚠️ THE EDGE DOT SHRINKS WHERE THE RUN CONTINUES, and that is the only
    /// thing left saying "there is more".
    ///
    /// Five identical dots at page one of twelve is a lie: it says five pages,
    /// you are on the first. Both directions are asserted, because a run
    /// continues on whichever side the viewer is not at.
    @Test func theEdgeDotShrinksOnTheSideTheRunContinues() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 12)
        dots.setCurrent(0)
        dots.layoutIfNeeded()

        let sizes = dots.debugDotSizes
        // At the start: nothing before, so the leading dot is full and the
        // trailing one is cut off.
        #expect(sizes.first == MediaPageIndicatorView.dotDiameter)
        #expect(sizes.last ?? 0 < MediaPageIndicatorView.dotDiameter)

        dots.setCurrent(11)
        dots.layoutIfNeeded()
        let atEnd = dots.debugDotSizes
        #expect(atEnd.last == MediaPageIndicatorView.dotDiameter)
        #expect(atEnd.first ?? 0 < MediaPageIndicatorView.dotDiameter)
    }

    /// And in the middle both edges are cut, because the run continues both ways.
    @Test func bothEdgesShrinkInTheMiddleOfALongRun() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 12)
        dots.setCurrent(6)
        dots.layoutIfNeeded()

        let sizes = dots.debugDotSizes
        #expect(sizes.first ?? 0 < MediaPageIndicatorView.dotDiameter)
        #expect(sizes.last ?? 0 < MediaPageIndicatorView.dotDiameter)
    }

    /// A gallery that fits has no continuation on either side, so nothing is
    /// cut — the shrink must mean something rather than being decoration.
    @Test func aGalleryThatFitsHasNoShrunkenEdges() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 4)
        dots.setCurrent(1)
        dots.layoutIfNeeded()

        #expect(dots.debugDotSizes.allSatisfy { $0 == MediaPageIndicatorView.dotDiameter })
    }

    // MARK: - The ends of the strip

    /// ⚠️ THE STRIP ENDS IN A FADE, NOT IN A CUT — on the sides that have
    /// somewhere to arrive from, and only those.
    ///
    /// A dot leaving the window crosses the container's edge, and a plain clip
    /// turned it into a half-moon on the way out: a shape no dot has at rest.
    /// All three positions are asserted together, because the fade is only
    /// meaningful if it tracks WHICH side the run continues on.
    @Test func theStripFadesOnlyWhereTheRunContinues() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 12)

        dots.setCurrent(0)
        dots.layoutIfNeeded()
        #expect(dots.debugEdgeFade == (leading: false, trailing: true))

        dots.setCurrent(6)
        dots.layoutIfNeeded()
        #expect(dots.debugEdgeFade == (leading: true, trailing: true))

        dots.setCurrent(11)
        dots.layoutIfNeeded()
        #expect(dots.debugEdgeFade == (leading: true, trailing: false))
    }

    /// ⚠️ THE DOTS VIEW REACHES THE CAPSULE'S ENDS.
    ///
    /// This is where the runway comes from: the chip's 12pt of horizontal
    /// padding moved INSIDE the dots view instead of sitting around it. Pinned
    /// at the chip level because that is the half a `PageDotsView` test cannot
    /// see — sizing a bare dots view to `chipWidth` would lay the window out
    /// correctly even if the chip still held the padding itself.
    @Test func theChipHandsItsPaddingToTheDots() {
        let chip = MediaPageIndicatorView()
        chip.configure(count: 12, current: 0)
        chip.frame = CGRect(origin: .zero, size: chip.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        ))
        chip.layoutIfNeeded()

        #expect(chip.bounds.width > 0)
        #expect(chip.debugDotsFrame.width == chip.bounds.width)
    }

    /// ⚠️ THE FADE NEVER TOUCHES A DOT THAT IS BEING READ.
    ///
    /// The fade lives on the runway — the padding the chip used to hold outside
    /// the dots view — so it ends exactly where the window begins. Get this
    /// wrong in the other direction and the fix for a cut edge becomes a dimmer
    /// on the dots the viewer is looking at, which is what a wider fade inside
    /// the window would have been.
    @Test func theFadeStopsWhereTheDotsStart() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 12)
        dots.setCurrent(6)
        dots.layoutIfNeeded()

        let extent = dots.debugFadeExtent
        let frames = dots.debugDotFrames
        #expect(extent.leading > 0)
        #expect(extent.trailing > 0)
        #expect((frames.first?.minX ?? 0) >= extent.leading)
        #expect((frames.last?.maxX ?? 0) <= dots.bounds.width - extent.trailing)
    }

    /// And the runway is real: a whole slot of it, on both sides, which is what
    /// a dot needs to fade out over instead of being sliced by the edge.
    @Test func theWindowIsLaidOutClearOfTheEdges() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 12)
        dots.setCurrent(6)
        dots.layoutIfNeeded()

        let frames = dots.debugDotFrames
        #expect((frames.first?.minX ?? 0) >= PageDotsView.overhang)
        #expect((frames.last?.maxX ?? 0) <= dots.bounds.width - PageDotsView.overhang)
    }

    /// ⚠️ THE DOT ONE SLOT OUT IS STILL WHOLLY INSIDE THE VIEW.
    ///
    /// This is the actual promise, and it is stronger than "it fades before it
    /// is cut": a dot leaving the window travels exactly one slot, and the
    /// runway is wider than a slot, so its leading edge never reaches the
    /// container's bound at all. There is nothing left for the clip to slice.
    ///
    /// Measured on the PARKED dots rather than the visible ones — a dot on its
    /// way out is precisely a dot that is no longer in the window, so the
    /// visible set is the one place this would never show up.
    @Test func theDotJustOutsideTheWindowNeverReachesTheEdge() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 12)
        dots.setCurrent(6)
        dots.layoutIfNeeded()

        // Window of 5 centred on page 6 starts at 4, so pages 3 and 9 are the
        // dots one slot outside it on either side.
        let frames = dots.debugAllDotFrames
        #expect(frames[3].minX > 0)
        #expect(frames[9].maxX < dots.bounds.width)
    }

    /// And a gallery that fits is not masked at all: nothing arrives or leaves,
    /// so a fade there would only dim the first and last dot for no reason.
    @Test func aGalleryThatFitsIsNotFaded() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 4)
        dots.setCurrent(1)
        dots.layoutIfNeeded()

        #expect(dots.debugEdgeFade == (leading: false, trailing: false))
    }
}
