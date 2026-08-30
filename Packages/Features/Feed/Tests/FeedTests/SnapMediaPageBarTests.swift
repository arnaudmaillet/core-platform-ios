import CoreModels
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// **THE POST SCREEN'S PAGE STRIP: one segment per picture, across the whole
/// width of the column.**
///
/// The card's chip of dots was the wrong instrument here and had been all
/// along. It is sized for a row of counters — five dots at most, a window
/// sliding through the rest — and this screen has the whole width and one
/// thing to say with it. It was also a small target floating over the
/// photograph, in the one place a tap already means play/pause.
///
/// So the strip says the thing a strip can say: every page gets a segment, and
/// a segment's LENGTH is its share of the width. Two pictures make two long
/// pills; twelve make twelve short ones, and the difference is read before it
/// is counted.
@MainActor
struct SnapMediaPageBarTests {
    private func bar(pages: Int, current: Int = 0, width: CGFloat = 370) -> SnapMediaPageBarView {
        let view = SnapMediaPageBarView(frame: CGRect(
            x: 0, y: 0, width: width, height: SnapMediaPageBarView.thickness
        ))
        view.configure(count: pages, current: current)
        view.layoutIfNeeded()
        return view
    }

    // MARK: - The strip

    /// The claim, as geometry: the segments SHARE the width — the run starts at
    /// one edge and ends at the other, with a gap between neighbours and
    /// nothing else.
    @Test func theSegmentsShareTheWholeWidth() throws {
        let width: CGFloat = 370
        let view = bar(pages: 3, current: 0, width: width)

        let first = try #require(view.debugSegmentFrame(0))
        let middle = try #require(view.debugSegmentFrame(1))
        let last = try #require(view.debugSegmentFrame(2))

        #expect(first.minX == 0)
        #expect(abs(last.maxX - width) < 0.5)
        #expect(abs(middle.minX - first.maxX - SnapMediaPageBarView.gap) < 0.5)
        // The pages you are not on are drawn alike; the one you are on is the
        // subject of the next case.
        #expect(abs(middle.width - last.width) < 0.5)
    }

    /// ⚠️ THE PAGE YOU ARE ON IS THE WIDE ONE — at least twice the rest, at any
    /// count, so the mark survives a glance at twelve pages where an even run
    /// of segments would just read as "uneven".
    @Test func thePageYouAreOnIsTheWideOne() throws {
        for pages in [2, 5, 13] {
            let view = bar(pages: pages, current: 1)
            let active = try #require(view.debugSegmentFrame(1))
            let resting = try #require(view.debugSegmentFrame(0))
            #expect(active.width >= resting.width * 2,
                    Comment(rawValue: "\(pages) pages: \(active.width) vs \(resting.width)"))
        }
    }

    /// ⚠️ AND THE WIDTHS TRANSPOSE THE SCROLL. Halfway between two pictures,
    /// both segments are half grown — the strip reflows across the whole
    /// gesture rather than snapping when the page number changes.
    @Test func theWidthsTransposeTheScroll() throws {
        let width: CGFloat = 370
        let view = bar(pages: 4, current: 1, width: width)
        let resting = try #require(view.debugSegmentFrame(3)).width
        let grown = try #require(view.debugSegmentFrame(1)).width

        view.setPosition(1.5)

        let half = try #require(view.debugSegmentFrame(1))
        let other = try #require(view.debugSegmentFrame(2))
        #expect(abs(half.width - other.width) < 0.5)   // shared exactly
        #expect(half.width > resting)
        #expect(half.width < grown)
        // ⚠️ AND THE RUN STILL SPANS THE COLUMN. The weights sum to the same
        // total at every position, so the strip never breathes at its ends —
        // which would read as a layout fault rather than as motion.
        #expect(try #require(view.debugSegmentFrame(0)).minX == 0)
        #expect(abs(try #require(view.debugSegmentFrame(3)).maxX - width) < 0.5)
    }

    /// The ink rides the same curve as the width: half grown is half lit.
    @Test func theInkTransposesTheScrollToo() throws {
        let view = bar(pages: 4, current: 1)
        view.setPosition(1.5)

        let one = try #require(view.debugSegmentAlpha(1))
        let two = try #require(view.debugSegmentAlpha(2))
        #expect(abs(one - two) < 0.01)
        #expect(one > SnapMediaPageBarView.restingAlpha)
        #expect(one < 1)
        #expect(try #require(view.debugSegmentAlpha(3)) < one)
    }

    /// ⚠️ AND A PAGE NUMBER MUST NOT FIGHT THE FINGER. The carousel reports
    /// both signals — a fraction on every scroll callback, a page number at the
    /// crossing — and halfway through a drag they are 0.52 and 1, both true. A
    /// strip that sprang to 1.0 on the second would jump ahead of the finger and
    /// be dragged back by the next fraction, once per crossing, for ever.
    @Test func aPageNumberTheStripAlreadyAgreesWithChangesNothing() throws {
        let view = bar(pages: 4, current: 0)
        view.setPosition(0.52)
        let midDrag = try #require(view.debugSegmentFrame(0)).width

        view.setCurrent(1) // the crossing's page number, arriving mid-drag

        #expect(try #require(view.debugSegmentFrame(0)).width == midDrag)
        // …and a page it does NOT agree with still moves it.
        view.setCurrent(3)
        #expect(try #require(view.debugSegmentFrame(3)).width
                > #require(view.debugSegmentFrame(0)).width)
    }

    /// ⚠️ NOTHING ANIMATES, and that absence is deliberate enough to pin.
    ///
    /// A bounce lived here twice — first at the crossing, where it stretched a
    /// segment while the widths were still reflowing under the finger, then at
    /// the settle, where it was at least alone. Both were removed: the strip
    /// already MOVES, because its widths and its ink are a function of the
    /// scroll, and an accent laid over a thing that is already moving is a
    /// second motion on one object however well timed. What reads as alive here
    /// is the reflow.
    @Test func nothingAboutTheStripAnimates() {
        let view = bar(pages: 4, current: 0)

        view.setPosition(0.6)   // across the crossing
        view.setPosition(1)     // and onto the page
        #expect(view.debugSegmentIsAnimating(0) == false)
        #expect(view.debugSegmentIsAnimating(1) == false)

        view.setCurrent(3)      // and a page arriving as a number
        #expect(view.debugSegmentIsAnimating(3) == false)
    }

    /// ⚠️ AND THAT IS WHY THEY ARE PILLS RATHER THAN DOTS. Few pictures means
    /// long segments — the shape carries the count, which a row of identical
    /// dots cannot do without being counted.
    @Test func fewerPicturesMakeLongerPills() throws {
        let two = try #require(bar(pages: 2).debugSegmentFrame(1))   // a resting one
        let six = try #require(bar(pages: 6).debugSegmentFrame(1))

        #expect(two.width > six.width * 2)
        // A pill, not a dot: far longer than it is tall.
        #expect(two.width > two.height * 4)
    }

    /// ⚠️ `alpha` is a `Float` behind a `CGFloat` face, so 0.35 does not come
    /// back as 0.35. The claim is the CONTRAST anyway — one segment is the ink,
    /// the rest are the same ink held back — so it is stated that way.
    @Test func theMarkIsThePageYouAreOn() throws {
        let view = bar(pages: 4, current: 2)
        #expect(try #require(view.debugSegmentAlpha(2)) == 1)
        #expect(try #require(view.debugSegmentAlpha(0)) < 0.5)
        #expect(try #require(view.debugSegmentAlpha(0)) == #require(view.debugSegmentAlpha(1)))

        view.setCurrent(0)
        #expect(try #require(view.debugSegmentAlpha(0)) == 1)
        #expect(try #require(view.debugSegmentAlpha(2)) < 0.5)
    }

    /// One picture has no position to report, and a single full-width pill
    /// would claim it did.
    @Test func onePictureShowsNoStripAtAll() {
        #expect(bar(pages: 1).isHidden)
        #expect(bar(pages: 2).isHidden == false)
    }

    /// ⚠️ THE DRAG TRACKS THE STRIP IT IS DRAWN ON. A segment's stride is one
    /// page here, so the mark keeps pace with the thumb — and touching it asks
    /// for nothing, which matters more on a full-width control than it did on
    /// the card's chip: an absolute read would send a twelve-page post to page
    /// six the moment a thumb landed near the middle of the screen.
    @Test func draggingAlongTheStripAsksForPagesAtItsOwnScale() {
        let width: CGFloat = 370
        let view = bar(pages: 4, width: width)
        var asked: [Int] = []
        view.onPageRequested = { asked.append($0) }

        let stride = (width + SnapMediaPageBarView.gap) / 4
        view.debugScrub(.began, atX: 20)
        #expect(asked.isEmpty) // the touch alone asks for nothing

        view.debugScrub(.changed, atX: 20 + stride)
        view.debugScrub(.changed, atX: 20 + stride * 2)
        #expect(asked == [1, 2])

        // Back past the start, and it clamps rather than going numb.
        view.debugScrub(.changed, atX: 20 - stride * 5)
        #expect(asked == [1, 2, 0])
    }

    // MARK: - The window, past ten pictures

    /// Which pages the strip is actually drawing — anything with ink.
    private func drawn(_ view: SnapMediaPageBarView, pages: Int) -> [Int] {
        (0..<pages).filter { (view.debugSegmentAlpha($0) ?? 0) > 0.02 }
    }

    /// ⚠️ TEN SEGMENTS, WHATEVER THE COUNT. Past that the strip stops being a
    /// diagram and becomes a texture — at twenty a segment is thinner than the
    /// gap beside it, and the mark's 2.6× is a few points of nothing.
    @Test func aLongRunIsDrawnTenSegmentsAtATime() {
        #expect(drawn(bar(pages: 10), pages: 10).count == 10)

        let long = bar(pages: 24)
        // Ten, plus whatever fraction of the eleventh is on its way in.
        #expect(drawn(long, pages: 24).count <= 11)
        #expect(drawn(long, pages: 24).count >= 10)
    }

    /// ⚠️ THE MARK WALKS; THE WINDOW ONLY FOLLOWS WHEN IT HAS TO — the card
    /// indicator's rule, and the reason it exists is that recomputing the
    /// window from the current page alone gives the mark a fixed slot and
    /// slides the whole run under it on every page, which shows the one thing
    /// that is happening as the one thing that does not move.
    @Test func theWindowHoldsStillWhileTheMarkWalksIntoIt() throws {
        let view = bar(pages: 24, current: 0)
        #expect(drawn(view, pages: 24).first == 0)

        view.setPosition(3)   // still well inside the window
        // ⚠️ The claim is MEMBERSHIP, not geometry. The widths move whatever
        // the window does — that is the mark growing — so a test that watched
        // an x-coordinate would be pinning the tent, not the window.
        #expect(drawn(view, pages: 24).first == 0)

        // The bound itself — the mark sits one slot in from the end it is
        // heading for, and the window still has not moved.
        view.setPosition(8)
        #expect(drawn(view, pages: 24).first == 0)

        // One page further, and from here the run scrolls under the mark.
        view.setPosition(9)
        #expect(try #require(drawn(view, pages: 24).first) > 0)
    }

    /// ⚠️ THE RUN TAPERS WHERE IT CONTINUES, AND ONLY THERE. The outermost
    /// segment narrowing says "there is more past here"; a window sitting on
    /// the true first page has nothing to promise on that side and says
    /// nothing.
    @Test func theRunTapersOnlyAtAnEndThatContinues() throws {
        let view = bar(pages: 24, current: 0)

        // The window sits on the true first page, so the leading end promises
        // nothing and is drawn flat: two interior segments, same width.
        #expect(abs(try #require(view.debugSegmentFrame(1)).width
                    - #require(view.debugSegmentFrame(2)).width) < 0.5)

        // The trailing end continues, and says so — narrower, and dimmer.
        let interior = try #require(view.debugSegmentFrame(5)).width
        #expect(try #require(view.debugSegmentFrame(9)).width < interior / 2)
        #expect(try #require(view.debugSegmentAlpha(9)) < #require(view.debugSegmentAlpha(5)))

        // ⚠️ And the taper is a SLOPE, not a cliff: the segment one in from the
        // end is part-way down, which is what says how the run is going.
        let penultimate = try #require(view.debugSegmentFrame(8)).width
        let outermost = try #require(view.debugSegmentFrame(9)).width
        #expect(penultimate < interior)
        #expect(penultimate > outermost)
    }

    /// ⚠️ AND THE MARK NEVER TAPERS, wherever the window parks it. The taper
    /// says "the run continues past here" and the mark says "you are here";
    /// the window puts the mark one slot in from the end it is heading for,
    /// which is exactly the slot the taper reaches, so the two collide by
    /// construction rather than by accident.
    @Test func theMarkNeverTapers() throws {
        let view = bar(pages: 24, current: 0)
        view.setPosition(12)   // travelling forward: the mark rides the bound

        let markWidth = try #require(view.debugSegmentFrame(12)).width
        let widest = (0..<24).compactMap { view.debugSegmentFrame($0)?.width }.max()
        #expect(markWidth == widest)
        #expect(try #require(view.debugSegmentAlpha(12)) == 1)
    }

    /// The window changes nothing about the promise the strip makes at rest:
    /// the run still spans the column exactly, at any position.
    @Test func theWindowedRunStillSpansTheColumn() throws {
        let width: CGFloat = 370
        let view = bar(pages: 24, current: 0, width: width)

        for position in [CGFloat(0), 3.5, 12, 17.25, 23] {
            view.setPosition(position)
            let ink = (0..<24).compactMap { index -> CGRect? in
                guard (view.debugSegmentAlpha(index) ?? 0) > 0.02 else { return nil }
                return view.debugSegmentFrame(index)
            }
            let leading = try #require(ink.map(\.minX).min())
            let trailing = try #require(ink.map(\.maxX).max())
            #expect(leading < 1, Comment(rawValue: "left a gap at \(position): \(leading)"))
            #expect(trailing > width - 1,
                    Comment(rawValue: "left a gap at \(position): \(trailing)"))
        }
    }

    // MARK: - Where it sits in the column

    private func chrome(pages: Int) -> SnapChromeView {
        let view = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 83, right: 0))
        view.configure(with: FeedItemDisplayModel(
            id: PostID("post-1"), authorID: ProfileID("a"), authorName: "Ava",
            metaText: "@ava · 3m", avatarURL: nil,
            caption: "A caption long enough to take the two lines the page reserves for it.",
            mediaURL: URL(string: "mock://video/1"), mediaKind: .video,
            thumbnailURL: nil, audioText: nil, likeCount: 0, timestampText: "now"
        ))
        view.setMediaPageCount(pages, current: 0)
        view.layoutIfNeeded()
        return view
    }

    /// ⚠️ BETWEEN THE CAPTION AND THE BAR, which is the whole point of moving
    /// it: the strip is the pictures' index and the caption is what they are
    /// about, so they share a column and an edge, and the toolbar's line is
    /// what the strip rests against.
    @Test func theStripSitsBetweenTheCaptionAndTheBar() {
        let view = chrome(pages: 3)
        let strip = view.debugPageBarFrame
        let caption = view.debugCaptionFrame

        #expect(strip.minY > caption.maxY)
        #expect(strip.maxY <= view.bounds.height - 83) // the toolbar's line
        #expect(abs(strip.minX - caption.minX) < 0.5)
        #expect(abs(strip.maxX - caption.maxX) < 0.5)
        #expect(strip.height == SnapMediaPageBarView.thickness)
    }

    /// ⚠️ AND ITS ARRIVAL MOVES NOTHING. A strip that pushed the caption up
    /// would give a collection a different resting geometry from every other
    /// format — which the hero flight's replica would then have to match, and
    /// the corner is deliberately format-agnostic (see `captionFloorGuide`).
    @Test func theStripsArrivalMovesNothingElse() {
        let withStrip = chrome(pages: 4)
        let without = chrome(pages: 0)

        #expect(withStrip.debugCaptionFrame == without.debugCaptionFrame)
        #expect(without.debugPageBar.isHidden)
    }
}
