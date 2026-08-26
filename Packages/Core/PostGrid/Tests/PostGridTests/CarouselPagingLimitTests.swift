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

    /// ⚠️ AND THE DRAG ITSELF COUNTS AS PART OF THE GESTURE.
    ///
    /// The clamp allows one page either side of an anchor, and the anchor used
    /// to be read when the finger LIFTED. By then a long swipe has already
    /// carried the content a page along, so the clamp permitted one MORE and
    /// the gesture landed two pages away — "if I slide hard I scroll several
    /// photos at once". Every test above this one set the offset to the anchor
    /// page and never moved it, so none of them could see it.
    ///
    /// Here the content is moved between the two delegate calls, which is what
    /// a real drag does.
    @Test func aLongDragEndingInAFlickStillMovesOnlyOnePage() {
        let view = carousel(pages: 12)
        view.setPage(4, animated: false)
        let scrollView = UIScrollView()
        scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: 4), y: 0)
        view.scrollViewWillBeginDragging(scrollView)
        // The finger has dragged a full page before letting go.
        scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: 5), y: 0)

        var target = CGPoint(x: view.debugOffset(forPage: 8), y: 0)
        withUnsafeMutablePointer(to: &target) {
            view.scrollViewWillEndDragging(
                scrollView, withVelocity: CGPoint(x: 6, y: 0), targetContentOffset: $0
            )
        }

        #expect(target.x == view.debugOffset(forPage: 5))
    }

    /// ⚠️ AND THE ANCHOR IS SPENT, so the NEXT gesture measures from where this
    /// one landed rather than from where the last one began.
    ///
    /// A stale anchor would pin the carousel to one page for ever: every
    /// subsequent flick would be clamped to within one page of a gesture the
    /// viewer finished long ago.
    @Test func eachGestureAnchorsWhereItStarts() {
        let view = carousel(pages: 12)
        let scrollView = UIScrollView()
        var landed = 0

        for expected in 1...3 {
            scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: landed), y: 0)
            view.scrollViewWillBeginDragging(scrollView)
            scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: landed + 1), y: 0)
            var target = CGPoint(x: view.debugOffset(forPage: 11), y: 0)
            withUnsafeMutablePointer(to: &target) {
                view.scrollViewWillEndDragging(
                    scrollView, withVelocity: CGPoint(x: 8, y: 0), targetContentOffset: $0
                )
            }
            #expect(target.x == view.debugOffset(forPage: expected))
            landed = expected
        }
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

    /// And dragging does — asserted beside its opposite, because a gesture that
    /// asks for nothing at all would satisfy the test above.
    @Test func draggingAdvancesFromWhereTheFingerLanded() {
        let indicator = MediaPageIndicatorView()
        indicator.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
        indicator.configure(count: 12, current: 3)
        var requested: [Int] = []
        indicator.onPageRequested = { requested.append($0) }

        indicator.debugScrub(.began, atX: 60)
        indicator.debugScrub(.changed, atX: 60 + MediaPageIndicatorView.pointsPerPage * 2)

        #expect(requested == [5])
    }

    /// ⚠️ WHERE YOU PRESS IS AN ORIGIN, NOT A COORDINATE.
    ///
    /// The touch used to be read absolutely — the strip divided into as many
    /// bands as there are pages — so landing on the middle of the chip
    /// teleported a twelve-page post to page six before the drag had moved at
    /// all. Both ends of the chip are pressed here, from the same page, to show
    /// the answer no longer depends on WHERE the finger went down.
    @Test func thePressPointDoesNotDecideThePage() {
        for x in [CGFloat(4), 60, 116] {
            let indicator = MediaPageIndicatorView()
            indicator.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
            indicator.configure(count: 12, current: 3)
            var requested: [Int] = []
            indicator.onPageRequested = { requested.append($0) }

            indicator.debugScrub(.began, atX: x)
            indicator.debugScrub(.changed, atX: x + MediaPageIndicatorView.pointsPerPage)

            #expect(requested == [4])
        }
    }

    /// A drag that goes nowhere asks for nothing, and a drag that comes back
    /// asks once — the host's answer to a request is to scroll a carousel, and
    /// `.changed` fires on every touch move.
    @Test func onlyAChangeOfPageIsRequested() {
        let indicator = MediaPageIndicatorView()
        indicator.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
        indicator.configure(count: 12, current: 5)
        var requested: [Int] = []
        indicator.onPageRequested = { requested.append($0) }

        indicator.debugScrub(.began, atX: 60)
        indicator.debugScrub(.changed, atX: 62)
        indicator.debugScrub(.changed, atX: 63)

        #expect(requested.isEmpty)
    }

    /// ⚠️ OVERSHOOTING MUST NOT GO NUMB.
    ///
    /// Drag well past the last page and a naive anchor is left that many pages
    /// out of range: the finger would have to travel all the way back before
    /// the strip moved again, which is exactly when the viewer is trying to
    /// correct. The anchor pins to the edge, so the way back responds on the
    /// first slot.
    @Test func comingBackFromPastTheEndRespondsImmediately() {
        let indicator = MediaPageIndicatorView()
        indicator.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
        indicator.configure(count: 12, current: 10)
        var requested: [Int] = []
        indicator.onPageRequested = { requested.append($0) }

        let slot = MediaPageIndicatorView.pointsPerPage
        indicator.debugScrub(.began, atX: 60)
        indicator.debugScrub(.changed, atX: 60 + slot * 20)   // far past the end
        indicator.debugScrub(.changed, atX: 60 + slot * 19)   // one slot back

        #expect(requested == [11, 10])
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

    /// ⚠️ AND THE TAPER IS TWO DOTS DEEP, not one.
    ///
    /// One step from full size to the smallest reads as a row that was CUT; a
    /// second dot at an intermediate size reads as a row that continues. The
    /// tests above assert only the outermost dot, so they pass on either shape
    /// — which is exactly why this one asserts the whole profile.
    @Test func theRunTapersOverTwoDotsOnEachContinuingSide() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 12)
        dots.setCurrent(6)
        dots.layoutIfNeeded()

        let sizes = dots.debugDotSizes
        let full = MediaPageIndicatorView.dotDiameter
        #expect(sizes.count == 5)
        // Small, semi, full — the slope on the side the viewer came from.
        #expect(sizes[0] < sizes[1])
        #expect(sizes[1] < sizes[2])
        #expect(abs(sizes[2] - full) < 0.5)
        // ⚠️ And the far side tapers in ONE step here, because the slot its
        // second step would use is where the MARK is — and the mark never
        // shrinks (see `theMarkIsNeverTapered`). The window trails the gesture,
        // so this is the ordinary case rather than a corner of it.
        #expect(abs(sizes[3] - full) < 0.5)
        #expect(sizes[4] < sizes[3])
        // The two ends still meet the run at the same size.
        #expect(abs(sizes[0] - sizes[4]) < 0.5)
    }

    /// ⚠️ THE MARK IS FULL SIZE WHEREVER THE WINDOW PUTS IT.
    ///
    /// The taper says "the run continues past here" and the mark says "you are
    /// here"; shrinking the second to tell you the first trades the one thing
    /// the indicator exists for against a hint its neighbours already give.
    ///
    /// Walked across the whole run rather than asserted at one page, because
    /// which slot the mark occupies is decided by the windowing rule — the very
    /// thing this must not depend on.
    @Test func theMarkIsNeverTapered() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 12)

        for page in 0..<12 {
            dots.setCurrent(page)
            dots.layoutIfNeeded()
            let mark = dots.debugAllDotFrames[page]
            #expect(abs(mark.width - MediaPageIndicatorView.dotDiameter) < 0.5)
        }
        // And walked BACK, since the window sits on the other side of the mark
        // when the direction reverses.
        for page in (0..<12).reversed() {
            dots.setCurrent(page)
            dots.layoutIfNeeded()
            let mark = dots.debugAllDotFrames[page]
            #expect(abs(mark.width - MediaPageIndicatorView.dotDiameter) < 0.5)
        }
    }

    /// ⚠️ AND ONLY ON THE SIDE THAT CONTINUES — including the middle dot.
    ///
    /// At the first page there is nothing before, so the leading THREE are full
    /// size and the taper is on the trailing end alone. A taper drawn on a side
    /// with nothing past it says "there is more" where there is not.
    @Test func theTaperIsOneSidedAtTheEndsOfTheRun() {
        let dots = PageDotsView()
        dots.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 6)
        dots.configure(count: 12)
        dots.setCurrent(0)
        dots.layoutIfNeeded()

        let sizes = dots.debugDotSizes
        let full = MediaPageIndicatorView.dotDiameter
        #expect(sizes.prefix(3).allSatisfy { abs($0 - full) < 0.5 })
        #expect(sizes[3] < full)
        #expect(sizes[4] < sizes[3])
    }

    /// ⚠️ THE CHIP HAS NO GROUND UNTIL IT IS TOUCHED, and it comes back when
    /// the finger leaves.
    ///
    /// Every other chip on these surfaces is a number, and a number over a
    /// photograph needs a floor to be legible on. The dots are their own
    /// contrast; a capsule around them at rest is a button nobody pressed.
    ///
    /// Asserted on the effect the chip is WEARING rather than on a flag of its
    /// own — the chip is a `UIVisualEffectView`, so that is the thing a viewer
    /// would see.
    @Test func theChipsGroundArrivesWithTheFinger() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        let chip = MediaPageIndicatorView()
        chip.configure(count: 8, current: 0)
        window.addSubview(chip)
        window.isHidden = false
        chip.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
        chip.layoutIfNeeded()

        #expect(chip.effect == nil)

        chip.debugScrub(.began, atX: 60)
        #expect(chip.effect != nil)

        chip.debugScrub(.ended, atX: 60)
        #expect(chip.effect == nil)
        window.isHidden = true
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

        // ⚠️ WHICH pages sit one slot out is ASKED, not assumed: the window
        // trails the direction of travel, so hard-coding the pair either side
        // would pin whichever rule was in force the day it was written — and
        // this test is about the RUNWAY, not about where the window starts.
        let visible = 5
        let start = PageDotsView.windowStart(current: 6, visible: visible, count: 12, direction: 1)
        let frames = dots.debugAllDotFrames
        #expect(frames[start - 1].minX > 0)
        #expect(frames[start + visible].maxX < dots.bounds.width)
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
