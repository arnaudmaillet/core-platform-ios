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

    /// Where the run of segments ENDS — which is no longer the edge of the
    /// column. The counter takes a corner at the trailing end and the run gets
    /// what is left, so every case that used to read "the run spans the width"
    /// reads "the run spans its own column" instead. Without a counter (a lone
    /// clip) the two are the same number.
    private func runEnd(of view: SnapMediaPageBarView, width: CGFloat) -> CGFloat {
        guard let counter = view.debugCounterFrame else { return width }
        return counter.minX - SnapMediaPageBarView.counterInset
    }

    // MARK: - The strip

    /// The claim, as geometry: the segments SHARE the run — it starts at the
    /// leading edge and ends where the counter's corner begins, with a gap
    /// between neighbours and nothing else.
    @Test func theSegmentsShareTheWholeWidth() throws {
        let width: CGFloat = 370
        let view = bar(pages: 3, current: 0, width: width)

        let first = try #require(view.debugSegmentFrame(0))
        let middle = try #require(view.debugSegmentFrame(1))
        let last = try #require(view.debugSegmentFrame(2))

        #expect(first.minX == 0)
        #expect(abs(last.maxX - runEnd(of: view, width: width)) < 0.5)
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
        #expect(abs(try #require(view.debugSegmentFrame(3)).maxX
                    - runEnd(of: view, width: width)) < 0.5)
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

    /// ⚠️ A DRAG ON A PHOTOGRAPH'S STRIP ASKS FOR NOTHING AT ALL.
    ///
    /// It used to page the carousel, one slot per segment — a second way to do
    /// what a swipe on the picture already does, on a control the width of the
    /// column, where the pages it walked past were the pages the media was
    /// flying through underneath. Selecting is what a strip of segments is for
    /// and a tap says it exactly; dragging is left to the one thing with no
    /// other control, which is where you are inside a clip.
    @Test func draggingAPhotographsStripAsksForNothing() {
        let width: CGFloat = 370
        let view = bar(pages: 4, width: width)
        var asked: [Int] = []
        view.onPageRequested = { asked.append($0) }

        let stride = (width + SnapMediaPageBarView.gap) / 4
        view.debugScrub(.began, atX: 20)
        view.debugScrub(.changed, atX: 20 + stride)
        view.debugScrub(.changed, atX: 20 + stride * 2)
        view.debugScrub(.ended, atX: 20 + stride * 2)

        #expect(asked.isEmpty)
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

    /// ⚠️ AND THE TAPER DISSOLVES AS THE RUN'S END COMES INTO VIEW, rather
    /// than switching off when it arrives.
    ///
    /// It was gated on a boolean — are there pages beyond this end — so sliding
    /// the window onto the last page flipped it, and the two tapered segments
    /// went from a sliver to full width between one frame and the next.
    /// Reported exactly that way: the last segment popping to normal size, with
    /// no animation, as you reach the second-to-last page. The fix is not an
    /// animation; it is measuring what was being asked as a yes-or-no.
    @Test func theTaperDissolvesAsTheRunsEndComesIntoView() throws {
        let view = bar(pages: 13, current: 0)
        var widths: [CGFloat] = []
        for position in [CGFloat(10), 10.5, 11] {
            view.setPosition(position)
            widths.append(try #require(view.debugSegmentFrame(12)).width)
        }

        #expect(widths[0] < widths[1], Comment(rawValue: "jumped: \(widths)"))
        #expect(widths[1] < widths[2], Comment(rawValue: "jumped: \(widths)"))
    }

    /// ⚠️ AND THE SAME AT THE OTHER END, which is where the report said it
    /// would be. The window is stateful — it only follows when it has to — so
    /// the walk back is driven as a walk back rather than as a jump.
    @Test func theTaperDissolvesTheSameWayComingBack() throws {
        let view = bar(pages: 13, current: 0)
        view.setPosition(11)   // out to the far end, so the window has travelled

        var widths: [CGFloat] = []
        for position in [CGFloat(2), 1.5, 1] {
            view.setPosition(position)
            widths.append(try #require(view.debugSegmentFrame(0)).width)
        }

        #expect(widths[0] < widths[1], Comment(rawValue: "jumped: \(widths)"))
        #expect(widths[1] < widths[2], Comment(rawValue: "jumped: \(widths)"))
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
            #expect(trailing > runEnd(of: view, width: width) - 1,
                    Comment(rawValue: "left a gap at \(position): \(trailing)"))
        }
    }

    // MARK: - A clip's own bar

    private func clipBar(pages: Int, current: Int, clips: Set<Int>,
                         playhead: Double?, width: CGFloat = 370) -> SnapMediaPageBarView {
        let view = SnapMediaPageBarView(frame: CGRect(
            x: 0, y: 0, width: width, height: SnapMediaPageBarView.thickness
        ))
        view.configure(count: pages, current: current, clipPages: clips)
        view.setPlayhead(playhead)
        view.layoutIfNeeded()
        return view
    }

    /// ⚠️ ON A CLIP, THE STRIP IS THE CLIP'S BAR. A video page has two things
    /// to say and they are the same shape — where you are in the post, and
    /// where you are in the picture — so the segment grows to nearly the whole
    /// width and carries the playhead, with the neighbours left as slivers.
    @Test func aClipsSegmentTakesNearlyTheWholeWidth() throws {
        let width: CGFloat = 370
        let view = clipBar(pages: 5, current: 2, clips: [2], playhead: 0.5, width: width)

        let bar = try #require(view.debugSegmentFrame(2))
        #expect(bar.width > runEnd(of: view, width: width) * 0.8)

        // The neighbours are still there — they are the only way back to the
        // other pages once the bar has taken the strip.
        #expect(try #require(view.debugSegmentFrame(1)).width > 4)
        #expect(try #require(view.debugSegmentFrame(3)).width > 4)
        // …and the pages beyond them are not.
        #expect(try #require(view.debugSegmentFrame(0)).width < 1)
        #expect(try #require(view.debugSegmentFrame(4)).width < 1)
    }

    /// The played part is drawn inside the bar, and it is the bright thing:
    /// the track steps back to the resting ink so a bar does not read as
    /// finished from its first frame.
    @Test func thePlayedPartIsDrawnInsideTheBar() throws {
        let view = clipBar(pages: 5, current: 2, clips: [2], playhead: 0.25)

        let bar = try #require(view.debugSegmentFrame(2))
        let played = try #require(view.debugFillFrame(2))
        #expect(abs(played.width - bar.width * 0.25) < 1)
        #expect(try #require(view.debugSegmentAlpha(2)) < 0.5)   // the track, not the fill
    }

    /// ⚠️ NIL IS AN ANSWER. A clip whose length is not known yet draws NO bar
    /// rather than an empty one: a bar at zero says "at the beginning", which
    /// is a different claim from "not yet known" and the one a viewer acts on.
    @Test func aClipWithNoKnownLengthDrawsNoBar() {
        let view = clipBar(pages: 5, current: 2, clips: [2], playhead: nil)
        #expect(view.debugFillFrame(2) == nil)
    }

    /// A photograph is a photograph: no bar, and the strip keeps its ordinary
    /// shape even on a post whose OTHER pages are clips.
    @Test func aPhotographKeepsTheOrdinaryStrip() throws {
        let view = clipBar(pages: 5, current: 0, clips: [2], playhead: 0.5)

        let mark = try #require(view.debugSegmentFrame(0))
        #expect(mark.width < 370 * 0.5)
        #expect(view.debugFillFrame(0) == nil)
    }

    // MARK: - What a touch means

    /// ⚠️ A TAP SELECTS, ABSOLUTELY. The card's chip refuses a tap because it is
    /// 50pt of dots between two counters; this strip is the width of the column,
    /// and once a clip's bar has taken it the slivers either side are the only
    /// way to the other pages.
    @Test func aTapAsksForTheSegmentUnderIt() throws {
        let view = bar(pages: 5, current: 0, width: 370)
        var asked: [Int] = []
        view.onPageRequested = { asked.append($0) }

        let third = try #require(view.debugSegmentFrame(3))
        view.debugTap(atX: third.midX)

        #expect(asked == [3])
    }

    /// ⚠️ AND A TAP ON A CLIP'S SLIVER ASKS FOR THAT PAGE — which is the whole
    /// reason the tap had to exist. Once the bar has taken the strip, the two
    /// slivers are the only way to the rest of the post.
    ///
    /// ⚠️ It is answered from the segments actually DRAWN. The pages beyond the
    /// slivers are squeezed to nothing, and a nearest-centre search that
    /// counted them answered with a page that is not on the strip: measured in
    /// the simulator as a tap on the right-hand sliver of an eight-page post
    /// jumping to page five.
    @Test func aTapOnAClipsSliverAsksForThatPage() throws {
        let view = clipBar(pages: 8, current: 3, clips: [3], playhead: 0.1)
        var asked: [Int] = []
        view.onPageRequested = { asked.append($0) }

        let right = try #require(view.debugSegmentFrame(4))
        view.debugTap(atX: right.midX)
        let left = try #require(view.debugSegmentFrame(2))
        view.debugTap(atX: left.midX)

        #expect(asked == [4, 2])
    }

    /// ⚠️ AND THE BAR FILLS THE COLUMN. A page squeezed to nothing still sat
    /// between two seams, so a long post spent seven gaps of pure air and the
    /// bar was that much shorter than it claimed.
    @Test func theClipsBarSpansTheColumnWithItsSlivers() throws {
        let width: CGFloat = 370
        let view = clipBar(pages: 8, current: 3, clips: [3], playhead: 0.1, width: width)

        let left = try #require(view.debugSegmentFrame(2))
        let bar = try #require(view.debugSegmentFrame(3))
        let right = try #require(view.debugSegmentFrame(4))
        #expect(left.minX < 1)
        #expect(right.maxX > runEnd(of: view, width: width) - 1)
        #expect(abs(bar.minX - left.maxX - SnapMediaPageBarView.gap) < 0.5)
        #expect(abs(right.minX - bar.maxX - SnapMediaPageBarView.gap) < 0.5)
    }

    /// ⚠️ AND A DRAG STILL MEANS THE PAGES, not a selection: the two must not
    /// both fire, or a scrub would end by teleporting to wherever the thumb
    /// happened to lift.
    @Test func aDragThatTravelsIsNotATap() {
        let view = bar(pages: 5, current: 0, width: 370)
        var asked: [Int] = []
        view.onPageRequested = { asked.append($0) }

        let stride = (370 + SnapMediaPageBarView.gap) / 5
        view.debugScrub(.began, atX: 20)
        view.debugScrub(.changed, atX: 20 + stride)
        view.debugScrub(.ended, atX: 20 + stride)

        // Nothing: the drag asks for nothing on a photograph, and a thumb that
        // travelled did not mean to select where it happened to lift.
        #expect(asked.isEmpty)
    }

    /// ⚠️ ON A CLIP, THE DRAG IS THE PLAYHEAD — the finer of the two things the
    /// strip offers. The pages are still reachable by tapping a sliver, which
    /// is why the tap had to exist before this could.
    @Test func draggingAClipsBarMovesThePlayheadAndNotThePages() {
        let view = clipBar(pages: 5, current: 2, clips: [2], playhead: 0.5)
        var pages: [Int] = []
        var seeks: [Double] = []
        view.onPageRequested = { pages.append($0) }
        view.onSeekRequested = { seeks.append($0) }

        let barWidth = view.debugSegmentFrame(2)?.width ?? 0
        view.debugScrub(.began, atX: 100)
        view.debugScrub(.changed, atX: 100 + barWidth * 0.25)

        #expect(pages.isEmpty)
        #expect(seeks.count == 1)
        // Relative to where the touch went down: half way, plus a quarter of
        // the bar, is three quarters — nothing jumped when the thumb landed.
        #expect(abs((seeks.first ?? 0) - 0.75) < 0.02)
    }

    /// And it clamps rather than running off either end of the clip.
    @Test func seekingPastTheEndsOfAClipClamps() {
        let view = clipBar(pages: 5, current: 2, clips: [2], playhead: 0.5)
        var seeks: [Double] = []
        view.onSeekRequested = { seeks.append($0) }

        view.debugScrub(.began, atX: 100)
        view.debugScrub(.changed, atX: 100 + 10_000)
        view.debugScrub(.changed, atX: 100 - 10_000)

        #expect(seeks.first == 1)
        #expect(seeks.last == 0)
    }

    /// ⚠️ THE RUN HANDS NOTHING BACK AT THE END OF A SWIPE.
    ///
    /// Reported as "the segments resize fine, but there is a slight jump right
    /// at the end" on a video, and it was one — not in the position, which is
    /// continuous, but in the WIDTHS, which briefly were not.
    ///
    /// A page's membership of the clip's shape was a boolean: `weight > 0`,
    /// which flips at exactly two slots away, which is exactly where a swipe
    /// onto that clip ends. The page that flips is a hair wide by then and
    /// invisible — but the GAPS are drawn from it, and two seams closing in one
    /// frame handed four points back to the run at the last moment of the
    /// gesture, which the bar spent in a surge after having been slowing down.
    ///
    /// So the claim is about the TOTAL: the run's widths sum to the same thing
    /// from one step of a swipe to the next. Measured before the fix, this walk
    /// stepped 4.08pt at the arrival; after it, 0.17pt.
    @Test func theRunHandsNoWidthBackAtTheEndOfASwipe() {
        let width: CGFloat = 370
        let view = clipBar(pages: 5, current: 1, clips: [2], playhead: 0.3, width: width)
        var previous: CGFloat?
        var worst: (step: CGFloat, at: CGFloat) = (0, 0)
        var position = CGFloat(1)
        while position <= 2.0001 {
            view.setPosition(position)
            view.layoutIfNeeded()
            let total = (0..<5)
                .compactMap { view.debugSegmentFrame($0)?.width }
                .reduce(0, +)
            if let previous, abs(total - previous) > worst.step {
                worst = (abs(total - previous), position)
            }
            previous = total
            position += 0.02
        }
        #expect(worst.step < 1,
                Comment(rawValue: "the run jumped \(worst.step)pt at \(worst.at)"))
    }

    // MARK: - The count in the corner

    /// ⚠️ THE COUNT IS THE ANSWER THE SEGMENTS CANNOT GIVE. A run of pills says
    /// where you are in a gallery and, once a window is sliding through a long
    /// one, stops being able to say how big the gallery is — and on a clip the
    /// run is a bar and says neither.
    @Test func theCornerCountsTheMediaAndTheTotal() {
        let view = bar(pages: 5, current: 0)
        #expect(view.debugCounterText == "1/5")

        view.setPosition(3)
        #expect(view.debugCounterText == "4/5")

        // ⚠️ It reads the page you are ON — the rounded position — so it
        // changes once, where the swipe crosses, rather than flickering
        // between two numbers for the length of a drag.
        view.setPosition(3.4)
        #expect(view.debugCounterText == "4/5")
        view.setPosition(3.6)
        #expect(view.debugCounterText == "5/5")
    }

    /// It counts past the window too: ten segments are drawn of twenty-four,
    /// and the corner is where the other fourteen are accounted for.
    @Test func theCountSurvivesTheWindow() {
        let view = bar(pages: 24, current: 0)
        view.setPosition(17)
        #expect(view.debugCounterText == "18/24")
    }

    /// A lone clip has nothing to count — "1/1" is a fact nobody asked for.
    @Test func aLoneClipCountsNothing() {
        let view = clipBar(pages: 1, current: 0, clips: [0], playhead: 0.3)
        #expect(view.debugCounterText == nil)
    }

    /// ⚠️ AND THE RUN GIVES UP THE ROOM. The counter's width comes from its
    /// text rather than from the column, so the segments take what is left —
    /// a run that ignored it would draw underneath it.
    @Test func theRunEndsWhereTheCountBegins() throws {
        let width: CGFloat = 370
        let view = bar(pages: 5, current: 0, width: width)

        let count = try #require(view.debugCounterFrame)
        let last = try #require(view.debugSegmentFrame(4))
        #expect(abs(count.maxX - width) < 0.5)
        #expect(last.maxX <= count.minX + 0.5)
        #expect(abs(count.minX - last.maxX - SnapMediaPageBarView.counterInset) < 0.5)
    }

    // MARK: - Consecutive clips, and the rest of the strip

    /// ⚠️ TWO CLIPS IN A ROW STAY A BAR ALL THE WAY ACROSS.
    ///
    /// Clipness was "how near is the nearest clip", and proximity is a tent
    /// whose halves add to one — so half way between one clip and the NEXT it
    /// read 0.5, and the strip dutifully blended half way back to its ordinary
    /// shape. The other pages flashed into view and out again between two
    /// videos, for no reason a viewer could name. Added rather than maximised,
    /// two consecutive clips hold it at 1 the whole way.
    @Test func aSwipeBetweenTwoClipsNeverBringsTheOtherPagesBack() throws {
        let view = clipBar(pages: 6, current: 1, clips: [1, 2], playhead: 0.2)

        for position in [CGFloat(1), 1.25, 1.5, 1.75, 2] {
            view.setPosition(position)
            // The pages beyond the pair and their slivers stay out of the way:
            // nothing two slots from the viewer is drawn.
            #expect(try #require(view.debugSegmentFrame(4)).width < 1,
                    Comment(rawValue: "page four came back at \(position)"))
            #expect(try #require(view.debugSegmentFrame(5)).width < 1,
                    Comment(rawValue: "page five came back at \(position)"))
        }
    }

    /// And a clip beside a PHOTOGRAPH still hands over — the strip is a bar at
    /// one end of the swipe and an ordinary run at the other.
    @Test func aSwipeFromAClipToAPhotographStillHandsOver() throws {
        let view = clipBar(pages: 6, current: 1, clips: [1], playhead: 0.2)
        let asBar = try #require(view.debugSegmentFrame(1)).width

        view.setPosition(2)   // onto the photograph

        #expect(try #require(view.debugSegmentFrame(2)).width < asBar / 2)
        #expect(try #require(view.debugSegmentFrame(4)).width > 4)   // the run is back
    }

    // MARK: - Resting and waking

    /// ⚠️ THE STRIP IS FURNITURE MOST OF THE TIME. It sits under the caption on
    /// every collection and every clip, and at full strength it competes with
    /// the words above it for a reading nobody is taking — you look at an index
    /// while you are moving. So it rests dim, comes up for as long as something
    /// is happening, and goes back down afterwards.
    ///
    /// ⚠️ Compared with a tolerance, because `alpha` is a `Float` behind a
    /// `CGFloat` face — 0.45 goes in and 0.44999998 comes back. The same trap
    /// this file already met on a segment's ink.
    @Test func theStripRestsDimAndWakesWhenTouched() {
        // ⚠️ THE CLAIM IS THE DIFFERENCE, not the constant. Written only against
        // `restingOpacity` this passes with the strip never dimmed at all —
        // both sides move together — so the first thing asserted is that
        // resting is dimmer than woken.
        #expect(SnapMediaPageBarView.restingOpacity < 1)

        let view = bar(pages: 5, current: 0)
        let rested = { abs(view.debugContainerOpacity - SnapMediaPageBarView.restingOpacity) < 0.001 }
        #expect(rested())

        view.debugTap(atX: 100)
        #expect(view.debugContainerOpacity == 1)

        view.debugElapseWake()
        #expect(rested())
    }

    /// ⚠️ AND THE PICTURES MOVING DOES *NOT* WAKE IT. It did, on the reading
    /// that the strip is about the pages and the pages were moving — but a
    /// viewer swiping through a gallery is looking at the gallery, and an index
    /// that brightens under every swipe is a second thing moving in the corner
    /// of the eye for the whole gesture. The strip comes up when it is TOUCHED:
    /// when it is being used, rather than when it merely has news.
    @Test func scrollingThePicturesDoesNotWakeTheStrip() {
        let view = bar(pages: 5, current: 0)
        view.debugElapseWake()

        view.setPosition(0.4)
        view.setPosition(1)

        #expect(abs(view.debugContainerOpacity - SnapMediaPageBarView.restingOpacity) < 0.001)
    }

    // MARK: - A lone clip

    /// ⚠️ A SINGLE PHOTOGRAPH HAS NO POSITION TO REPORT; A SINGLE CLIP DOES.
    /// One full-width pill under a photograph would claim an index it does not
    /// have — but where you are in a clip is a real answer, so the strip is
    /// drawn for one page and becomes that clip's bar.
    @Test func aLoneClipGetsABarAndALonePhotographGetsNothing() throws {
        let photograph = clipBar(pages: 1, current: 0, clips: [], playhead: nil)
        #expect(photograph.isHidden)

        let width: CGFloat = 370
        let clip = clipBar(pages: 1, current: 0, clips: [0], playhead: 0.4, width: width)
        #expect(clip.isHidden == false)
        #expect(try #require(clip.debugSegmentFrame(0)).width > width - 1)
        #expect(abs(try #require(clip.debugFillFrame(0)).width - width * 0.4) < 1)
    }

    /// ⚠️ A TAP ON A BAR IS A TAP ON A CLIP, so it means "go to that moment" —
    /// the page it lands on is the page you are already on. On a lone clip it
    /// is the only instruction the strip can carry at all.
    @Test func aTapOnTheBarMovesThePlayhead() {
        let width: CGFloat = 370
        let view = clipBar(pages: 1, current: 0, clips: [0], playhead: 0.1, width: width)
        var seeks: [Double] = []
        var pages: [Int] = []
        view.onSeekRequested = { seeks.append($0) }
        view.onPageRequested = { pages.append($0) }

        view.debugTap(atX: width * 0.75)

        #expect(pages.isEmpty)
        #expect(abs((seeks.first ?? 0) - 0.75) < 0.02)
    }

    // MARK: - Pointing with a card

    /// ⚠️ THE CARD IS PART OF THE GESTURE, so the strip says where the thumb is
    /// pointing separately from what it is asking for. A preview that arrived
    /// late must be able to be ignored; a seek must not be re-issued because a
    /// picture turned up.
    @Test func draggingAClipsBarSaysWhereTheThumbIsPointing() {
        let width: CGFloat = 370
        let view = clipBar(pages: 1, current: 0, clips: [0], playhead: 0.2, width: width)
        var pointed: [(fraction: Double, x: CGFloat)] = []
        var ended = 0
        view.onScrubPreview = { preview in
            if let preview { pointed.append(preview) } else { ended += 1 }
        }

        view.debugScrub(.began, atX: 100)
        view.debugScrub(.changed, atX: 100 + width * 0.3)
        #expect(pointed.count == 1)
        #expect(abs((pointed.first?.fraction ?? 0) - 0.5) < 0.02)   // 0.2 + 0.3
        #expect(pointed.first?.x == 100 + width * 0.3)

        view.debugScrub(.ended, atX: 100 + width * 0.3)
        #expect(ended == 1)
    }

    /// ⚠️ AND A CANCELLED GESTURE TAKES IT AWAY TOO. A rule written only for
    /// `.ended` leaves the card on screen when the system takes the touch back
    /// — which happens on every interruption a phone can have.
    @Test func aCancelledScrubAlsoTakesTheCardAway() {
        let view = clipBar(pages: 1, current: 0, clips: [0], playhead: 0.2)
        var ended = 0
        view.onScrubPreview = { if $0 == nil { ended += 1 } }

        view.debugScrub(.began, atX: 100)
        view.debugScrub(.changed, atX: 160)
        view.debugScrub(.cancelled, atX: 160)

        #expect(ended == 1)
    }

    /// The readout is the half that always works, so it is stated exactly:
    /// the moment under the thumb, and the length it is a part of.
    @Test func theCardReadsTheMomentAndTheLength() {
        let card = SnapScrubPreviewView()
        card.show(fraction: 0.5, seconds: 184)   // 3:04 of 3:04… half of it
        #expect(card.debugTimestamp == "1:32 / 3:04")

        card.show(fraction: 0.25, seconds: 7325) // past an hour, so hours show
        #expect(card.debugTimestamp == "30:31 / 2:02:05")
    }

    /// ⚠️ THE CARD KEEPS THE LAST FRAME IT HAD. A decode that fails or arrives
    /// late must change nothing on screen: the thumb has moved a little, not
    /// somewhere else, and a card that blanked between frames would flicker its
    /// way along a drag.
    @Test func theCardHoldsItsLastFrameWhileTheNextIsDecoding() throws {
        let card = SnapScrubPreviewView()
        card.show(fraction: 0.2, seconds: 60)
        card.setPicture(try Self.aFrame())
        #expect(card.debugHasPicture)

        // The next one is on its way…
        card.setLoading(true)
        card.debugElapseLoaderGrace()

        #expect(card.debugHasPicture)          // …and the last one is still up
        #expect(card.debugIsLoading == false)  // …with no spinner over it
    }

    /// ⚠️ AND IT SAYS IT IS WAITING ONLY WHEN IT HAS NOTHING. A spinner over a
    /// frame would be an apology for a picture that is already there.
    @Test func theCardSpinsOnlyWithNoFrameAtAll() {
        let card = SnapScrubPreviewView()
        card.show(fraction: 0.2, seconds: 60)

        card.setLoading(true)
        #expect(card.debugIsLoading == false)  // …after a fifth of a second, not before
        card.debugElapseLoaderGrace()
        #expect(card.debugIsLoading)

        card.setLoading(false)
        #expect(card.debugIsLoading == false)
    }

    /// A 1×1 frame — the spec is about what the card DOES with a picture, not
    /// about the picture.
    private static func aFrame() throws -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return try #require(image.cgImage)
    }

    /// ⚠️ AND A CARD WITH NO FRAME IS STILL A CARD. Not every asset gives up a
    /// still on demand, and the time is what the viewer is reading while they
    /// drag — so nothing about the readout waits for a picture.
    @Test func theCardShowsItsTimeWithNoPictureAtAll() {
        let card = SnapScrubPreviewView()
        card.show(fraction: 0.5, seconds: 60)

        #expect(card.debugIsShowing)
        #expect(card.debugHasPicture == false)
        #expect(card.debugTimestamp == "0:30 / 1:00")
    }

    // MARK: - What a tap on a segment asks the carousel for

    /// A post of several pictures, in a cell, so the request a tap makes can be
    /// followed all the way to the pages it moves.
    private func collectionCell(pages: Int) -> SnapFeedCell {
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let extra = (1..<pages).map { index in
            GalleryPost.MediaPage(
                thumbnailURL: URL(string: "https://example.test/thumb-\(index).jpg"),
                videoURL: nil
            )
        }
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-gallery"), authorID: ProfileID("p"), authorName: "Ava",
                metaText: "@ava · 3m", avatarURL: nil, caption: "caption",
                mediaURL: URL(string: "https://example.test/thumb-0.jpg"),
                mediaKind: .image, thumbnailURL: nil, audioText: nil,
                likeCount: 0, timestampText: "now", extraMedia: extra
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
        cell.layoutIfNeeded()
        return cell
    }

    /// ⚠️ THE JOURNEY IS NOT SHOWN AND THE ARRIVAL IS.
    ///
    /// Reported twice, and the second report is what settled the shape. First:
    /// aiming at a segment near the far end sent the carousel sprinting through
    /// every picture in between — six pictures thrown past the viewer at a speed
    /// that makes them noise, to arrive somewhere they could see from the start.
    /// Cutting straight there fixed that and broke something else: the taps that
    /// cut no longer played the strip's reflow at all, which reads as the
    /// control being broken on exactly the taps that travel furthest.
    ///
    /// So neither. The carousel is put down NEXT DOOR to the target without a
    /// word, and then turns the last page. Every tap ends in the same motion
    /// whatever it was aimed at, and no picture the viewer did not ask for is
    /// shown on the way.
    ///
    /// ⚠️ READ AS THE DECISIONS, NOT AS THE MOTION — and that is not a shortcut.
    /// A scroll view with no window applies an animated offset immediately, so
    /// a case that watched the pages would find a turn and a jump identical and
    /// pass whichever rule it was handed. Measured: asking for the neighbour
    /// with `animated: true` left the carousel on page one before the next line
    /// ran. What is worth pinning is the sequence; the easing is UIKit's.
    @Test func aFarTapArrivesNextDoorInSilenceAndThenTurnsThePage() {
        let cell = collectionCell(pages: 6)
        #expect(cell.debugCurrentMediaPage == 0, "the premise")

        // The neighbour: one instruction, and it is the turn.
        cell.debugClearPageRequests()
        cell.debugRequestMediaPage(1)
        #expect(cell.debugPageRequests.map(\.page) == [1])
        #expect(cell.debugPageRequests.map(\.animated) == [true])

        // Four away: put down at four in silence, then the page turns onto five.
        cell.debugClearPageRequests()
        cell.debugRequestMediaPage(5)
        #expect(cell.debugPageRequests.map(\.page) == [4, 5])
        #expect(cell.debugPageRequests.map(\.animated) == [false, true])
        #expect(cell.debugCurrentMediaPage == 5, "and it arrived")

        // ⚠️ AND IT APPROACHES FROM THE SIDE IT IS COMING FROM. Travelling back
        // down the run, next door is the segment ABOVE the target, not below —
        // approaching from the wrong side would turn the page backwards onto a
        // picture the viewer had just been shown.
        cell.debugClearPageRequests()
        cell.debugRequestMediaPage(0)
        #expect(cell.debugPageRequests.map(\.page) == [1, 0])
        #expect(cell.debugPageRequests.map(\.animated) == [false, true])

        // And a neighbour on the way back is still just a turn.
        cell.debugClearPageRequests()
        cell.debugRequestMediaPage(1)
        #expect(cell.debugPageRequests.map(\.page) == [1])
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

    /// ⚠️ THE CARD POINTS FROM ABOVE THE STRIP, AND STAYS INSIDE THE COLUMN.
    /// It is a label on the strip: one that ran past the strip's own ends would
    /// point at nothing, and one that pushed anything else around would make
    /// the layout move because a finger touched it.
    @Test func theScrubCardFollowsTheThumbWithinTheColumn() {
        let view = chrome(pages: 1)
        view.setMediaPageCount(1, current: 0, clipPages: [0])
        view.setMediaPlayhead(0.2, seconds: 120)
        view.layoutIfNeeded()
        let strip = view.debugPageBarFrame
        let caption = view.debugCaptionFrame

        view.debugPageBar.debugScrub(.began, atX: strip.width / 2)
        view.debugPageBar.debugScrub(.changed, atX: strip.width / 2 + 40)
        let middle = view.debugScrubPreviewFrame()
        // Directly above the strip, and OVER whatever is there — the caption is
        // the page talking about the post, and a pointer that waited for empty room
        // would have to sit somewhere that is not where the thumb is. It floats,
        // it is transient, and it moves nothing (asserted at the end).
        #expect(middle.maxY <= strip.minY)
        #expect(middle.minY < caption.maxY)
        #expect(middle.minX >= strip.minX - 0.5)
        #expect(middle.maxX <= strip.maxX + 0.5)

        // Dragged to the far end, it stops at the column's edge rather than
        // running off it.
        view.debugPageBar.debugScrub(.changed, atX: strip.width * 4)
        let far = view.debugScrubPreviewFrame()
        #expect(far.maxX <= strip.maxX + 0.5)
        #expect(far.minX > middle.minX)

        // …and the caption has not moved for any of it.
        #expect(view.debugCaptionFrame == caption)

        // ⚠️ AND THE CARD IS IN FRONT OF EVERYTHING. It is built with the strip,
        // and the surfaces added after it are its own siblings — the shortcut
        // wheel, the boost anchor, the subtitle zone, the comment empty state —
        // so a card added once sits UNDER the comment surfaces it is meant to
        // point over. Reported exactly that way.
        #expect(view.subviews.last === view.debugScrubPreview)
    }

    /// ⚠️ AND ITS ARRIVAL MOVES NOTHING. A strip that pushed the caption up
    /// would give a collection a different resting geometry from every other
    /// format — which the hero flight's replica would then have to match, and
    /// the corner is deliberately format-agnostic (see `captionFloorGuide`).
    /// ⚠️ AND IT STOPS SHORT OF THE TOOLBAR'S LINE. Flush against it the strip
    /// and the bar's glass read as one stacked control, which is the one thing
    /// they are not: the strip is the pictures' index, the bar is what you can
    /// DO to the post.
    @Test func theStripStopsShortOfTheToolbarsLine() {
        let view = chrome(pages: 3)
        let toolbarLine = view.bounds.height - 83

        let gap = toolbarLine - view.debugPageBarFrame.maxY
        #expect(abs(gap - SnapChromeView.pageBarToolbarGap) < 0.5,
                Comment(rawValue: "the strip left \(gap)pt"))
    }

    // MARK: - What a scrub takes away

    /// ⚠️ THE PAGE'S TALK RECEDES UNDER A SCRUB, AND COMES BACK.
    ///
    /// A viewer dragging along a clip's bar is looking for a MOMENT in the
    /// picture, and the card showing it is a small thing over a page still
    /// carrying its caption, its comments and its rail. So the page recedes for
    /// the length of the gesture.
    ///
    /// ⚠️ RESTORED, not asserted. Several of these are faded by someone else
    /// for their own reasons, so the fade back returns each to what it was
    /// worth rather than to full — which is what this case actually checks by
    /// comparing against the values it read before the gesture.
    @Test func theScrubTakesThePagesTalkDownAndGivesItBack() {
        let view = chrome(pages: 1)
        view.setMediaPageCount(1, current: 0, clipPages: [0])
        view.setMediaPlayhead(0.2, seconds: 120)
        view.layoutIfNeeded()
        let resting = view.debugScrubFadedAlphas

        let bar = view.debugPageBar
        bar.debugScrub(.began, atX: 100)
        bar.debugScrub(.changed, atX: 140)
        #expect(view.debugScrubFadedAlphas.allSatisfy { $0 == 0 })

        bar.debugScrub(.ended, atX: 140)
        #expect(view.debugScrubFadedAlphas == resting)
    }

    /// ⚠️ AND A CELL RECYCLED MID-SCRUB HANDS BACK WHAT IT BORROWED.
    ///
    /// A gesture does not have to END for the cell to be taken away — the post
    /// can be swiped off under the thumb — and a chrome that only restored on
    /// `.ended` would give the NEXT post a caption and a band that never come
    /// back. The trap the reset already carries for the engagement's fade, one
    /// gesture further in.
    @Test func aRecycleMidScrubGivesThePagesTalkBack() {
        let view = chrome(pages: 1)
        view.setMediaPageCount(1, current: 0, clipPages: [0])
        view.setMediaPlayhead(0.2, seconds: 120)
        view.layoutIfNeeded()
        let resting = view.debugScrubFadedAlphas

        let bar = view.debugPageBar
        bar.debugScrub(.began, atX: 100)
        bar.debugScrub(.changed, atX: 140)
        #expect(view.debugScrubFadedAlphas.allSatisfy { $0 == 0 }, "the premise")

        // Taken away with the thumb still down.
        view.reset()

        #expect(view.debugScrubFadedAlphas == resting)
    }

    /// And the strip itself never fades: it is the instrument in the hand.
    @Test func theScrubLeavesTheStripAndItsCardAlone() {
        let view = chrome(pages: 1)
        view.setMediaPageCount(1, current: 0, clipPages: [0])
        view.setMediaPlayhead(0.2, seconds: 120)
        view.layoutIfNeeded()

        let bar = view.debugPageBar
        bar.debugScrub(.began, atX: 100)
        bar.debugScrub(.changed, atX: 140)

        #expect(bar.alpha == 1)
        #expect(view.debugScrubPreview.alpha == 1)
    }

    @Test func theStripsArrivalMovesNothingElse() {
        let withStrip = chrome(pages: 4)
        let without = chrome(pages: 0)

        #expect(withStrip.debugCaptionFrame == without.debugCaptionFrame)
        #expect(without.debugPageBar.isHidden)
    }
}
