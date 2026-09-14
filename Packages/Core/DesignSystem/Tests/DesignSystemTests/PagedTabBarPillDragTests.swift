import Testing
import UIKit
@testable import DesignSystem

/// Dragging the selection pill.
///
/// A touch that goes down ON the pill picks it up and the pages run under the
/// finger; a touch anywhere else on the capsule scrolls the strip, exactly as
/// every touch used to. The rule is WHERE the finger landed, and these are the
/// tests of that word — a gesture recognizer cannot be driven from a unit test,
/// so the drag is entered through the same three functions the recognizer calls
/// (`debugBeginPillDrag`, `debugDragPill`, `debugEndPillDrag`), which is the
/// shipping path and not a copy of it.
@MainActor
struct PagedTabBarPillDragTests {
    private static let three = ["Activity", "Gallery", "Short"]
    private static let five = ["Activity", "Gallery", "Short", "Saved", "Reactions"]

    private func bar(_ titles: [String] = three, width: CGFloat = 360) -> PagedTabBar {
        let bar = PagedTabBar(titles: titles, style: .floating)
        bar.frame = CGRect(x: 0, y: 0, width: width, height: PagedTabBar.Style.floating.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    /// Where a finger would have to land to pick the pill up.
    private func pillCentre(_ bar: PagedTabBar) -> CGFloat { bar.debugPillInViewport.midX }

    // MARK: - Whose touch is it

    @Test func aTouchOnThePillPicksItUp() {
        let bar = bar()
        #expect(bar.debugBeginsPillDrag(atViewportX: pillCentre(bar)))
    }

    /// ⚠️ **The other segments belong to the strip.** This is the whole rule:
    /// the previous drag could be grabbed anywhere on the capsule, which is why
    /// it had to be switched off entirely whenever the strip had somewhere to
    /// scroll.
    @Test func aTouchOnAnotherSegmentDoesNot() {
        let bar = bar()
        let elsewhere = bar.debugPillInViewport.maxX + 30
        #expect(bar.debugBeginsPillDrag(atViewportX: elsewhere) == false)
    }

    /// And the answer follows the selection: after the pages move, the pill is
    /// somewhere else and so is the grab.
    @Test func theGrabFollowsTheSelection() {
        let bar = bar()
        let wasPill = pillCentre(bar)
        bar.setProgress(2)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(bar.debugBeginsPillDrag(atViewportX: pillCentre(bar)))
        #expect(bar.debugBeginsPillDrag(atViewportX: wasPill) == false)
    }

    /// A bar with one tab has no pages to run and nothing to drag.
    @Test func aSingleTabIsNotDraggable() {
        let bar = bar(["Activity"])
        #expect(bar.debugBeginsPillDrag(atViewportX: pillCentre(bar)) == false)
    }

    // MARK: - The pill follows the finger

    /// The pill is under the finger, not merely moved by it: a drag of N points
    /// moves the pill N points, not some multiple of a segment's width.
    @Test func thePillTravelsWithTheFinger() {
        let bar = bar()
        let start = pillCentre(bar)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        bar.debugDragPill(toViewportX: start + 40)
        #expect(abs(pillCentre(bar) - (start + 40)) < 1.5)
    }

    /// ⚠️ **The grip is kept.** Grabbed near its edge, the pill must not jump
    /// its centre under the finger — it travels by what the finger travelled.
    @Test func aPillGrabbedOffCentreDoesNotJump() {
        let bar = bar()
        let pill = bar.debugPillInViewport
        let held = pill.minX + 4
        let centreBefore = pill.midX
        #expect(bar.debugBeginPillDrag(atViewportX: held))
        bar.debugDragPill(toViewportX: held + 25)
        #expect(abs(pillCentre(bar) - (centreBefore + 25)) < 1.5)
    }

    /// Dragged onto the next segment, the drag reports 1 — the pages are a
    /// whole page along.
    @Test func aDragOntoTheNextSegmentReportsAWholePage() {
        let bar = bar()
        var reported: [CGFloat] = []
        bar.onScrub = { reported.append($0) }
        let start = pillCentre(bar)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        let next = start + bar.debugSegmentFrames[1].midX - bar.debugSegmentFrames[0].midX
        bar.debugDragPill(toViewportX: next)
        #expect(abs((reported.last ?? 0) - 1) < 0.02)
    }

    /// Every frame reports, which is what lets a host scrub its pager rather
    /// than jump it.
    @Test func everyFrameOfTheDragIsReported() {
        let bar = bar()
        var reported: [CGFloat] = []
        bar.onScrub = { reported.append($0) }
        let start = pillCentre(bar)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        for step in stride(from: CGFloat(4), through: 40, by: 4) {
            bar.debugDragPill(toViewportX: start + step)
        }
        #expect(reported.count >= 8)
        #expect(reported == reported.sorted())
    }

    /// Dragged past the last tab, it stops at the last tab — there is no page
    /// beyond it to report.
    @Test func theDragIsClampedToTheTabsThatExist() {
        let bar = bar()
        var reported: [CGFloat] = []
        bar.onScrub = { reported.append($0) }
        let start = pillCentre(bar)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        bar.debugDragPill(toViewportX: start + 5_000)
        #expect(reported.last == 2)
        bar.debugDragPill(toViewportX: start - 5_000)
        #expect(reported.last == 0)
    }

    // MARK: - What the drag does NOT do

    /// ⚠️ **A drag never announces `.valueChanged`.** Where the pages land is
    /// the pager's answer; a bar that announced as well would commit the host's
    /// model twice, to two answers.
    @Test func aDragAnnouncesNothing() {
        let bar = bar()
        var announced = 0
        bar.addAction(UIAction { _ in announced += 1 }, for: .valueChanged)
        bar.onScrub = { _ in }
        bar.onScrubEnd = { _ in }
        let start = pillCentre(bar)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        bar.debugDragPill(toViewportX: start + 60)
        bar.debugEndPillDrag()
        #expect(announced == 0)
    }

    /// ⚠️ The strip stands down for the length of the drag, and takes its
    /// scrolling back afterwards. Left off, the viewer could never scroll the
    /// strip again; left on, the strip's own pan would begin mid-drag and
    /// `keepLensVisible` would stop moving it.
    @Test func theStripStandsDownOnlyForTheDrag() {
        let bar = bar()
        #expect(bar.debugStripAcceptsScrolling)
        #expect(bar.debugBeginPillDrag(atViewportX: pillCentre(bar)))
        #expect(bar.debugStripAcceptsScrolling == false)
        bar.debugEndPillDrag()
        #expect(bar.debugStripAcceptsScrolling)
    }

    /// ⚠️ **A finger that never travels moves NOTHING** — not the pill, not the
    /// pages. The gate used to be split: the pages moved on the first point of
    /// travel while the release was gated on the slop, so a wobble under a
    /// fingertip scrubbed the pager a fraction of a page and let go of it with
    /// no settle coming.
    @Test func aTouchBelowTheSlopDoesNothingAtAll() {
        let bar = bar()
        var reported: [CGFloat] = []
        var released = 0
        bar.onScrub = { reported.append($0) }
        bar.onScrubEnd = { _ in released += 1 }
        let start = pillCentre(bar)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        bar.debugDragPill(toViewportX: start + 2)
        bar.debugDragPill(toViewportX: start + 1)
        bar.debugEndPillDrag()
        #expect(reported.isEmpty, "the pages moved for a press that never travelled")
        #expect(released == 0, "a tap published a release")
        #expect(abs(pillCentre(bar) - start) < 0.5)
    }

    /// ⚠️ **The end-of-strip scroller is ARMED BY THE GRAB**, not by the test.
    /// Nothing else can see this: a `CADisplayLink`'s ticks are not something a
    /// test can wait for, so without this the whole auto-scroll could be wired
    /// to nothing and every other test here would still pass.
    @Test func theGrabArmsTheEndOfStripScroller() {
        let bar = bar(Self.five, width: 260)
        #expect(bar.debugEdgeScrollIsArmed == false)
        #expect(bar.debugBeginPillDrag(atViewportX: pillCentre(bar)))
        #expect(bar.debugEdgeScrollIsArmed)
        bar.debugEndPillDrag()
        #expect(bar.debugEdgeScrollIsArmed == false)
    }

    /// ⚠️ And a still finger inside an end zone scrolls nothing. The last tab's
    /// pill RESTS inside that zone, so a scroller gated on the zone alone would
    /// run for a plain tap on it and carry the pages away.
    @Test func aStillFingerInTheEndZoneScrollsNothing() {
        let bar = bar(Self.five, width: 260)
        #expect(bar.debugOverflow > 0)
        // A MIDDLE tab, so the strip still has somewhere to go — pinned at
        // either end the clamp would refuse the scroll for a reason that has
        // nothing to do with the rule under test. `keepLensVisible` reveals the
        // selection at the trailing edge, so the pill now rests INSIDE the end
        // zone, which is the whole hazard: a tap on it must not scroll.
        bar.setProgress(2)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        let resting = bar.debugStripOffset
        #expect(resting < bar.debugOverflow, "the strip is already at its end; nothing to prove")
        let touch = bar.debugPillInViewport.maxX - 2
        #expect(touch > bar.debugViewportWidth - 36, "the touch is not in the end zone")
        #expect(bar.debugBeginPillDrag(atViewportX: touch))
        for _ in 0..<30 { bar.debugStepEdgeScroll() }
        #expect(bar.debugStripOffset == resting)
        bar.debugEndPillDrag()
    }

    // MARK: - The release

    /// The release hands over how fast the pill was going, signed, so the pager
    /// can carry a flick through instead of falling back.
    @Test func aReleaseHandsOverItsVelocity() {
        let bar = bar()
        var velocity: CGFloat?
        bar.onScrub = { _ in }
        bar.onScrubEnd = { velocity = $0 }
        let start = pillCentre(bar)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        bar.debugDragPill(toViewportX: start + 30)
        bar.debugDragPill(toViewportX: start + 60)
        bar.debugEndPillDrag()
        #expect((velocity ?? 0) > 0)
    }

    /// ⚠️ **With nothing wired to it the lens still lands on a tab.** A bar in
    /// an audit or a test has no pager to ride home, and a pill left between two
    /// tabs is the one state this control must never rest in.
    @Test(arguments: [CGFloat(10), 30, 55, 80, 200])
    func aReleaseWithNoPagerStillLandsOnATab(travel: CGFloat) {
        let bar = bar()
        let start = pillCentre(bar)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        bar.debugDragPill(toViewportX: start + travel)
        bar.debugEndPillDrag()
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        guard let alignment = bar.debugLensAlignment else { return #expect(Bool(false)) }
        #expect(abs(alignment.lens.midX - alignment.segment.midX) < 1)
    }

    // MARK: - The ends of the strip

    /// ⚠️ **A finger held against the end of a crowded strip keeps it moving.**
    /// This is the half `keepLensVisible` cannot do: it only runs when the
    /// finger MOVES, so holding at the edge would otherwise freeze two segments
    /// short of the tab being reached for.
    @Test func holdingAtTheTrailingEndScrollsTheStrip() {
        let bar = bar(Self.five, width: 260)
        #expect(bar.debugOverflow > 0)
        #expect(bar.debugBeginPillDrag(atViewportX: pillCentre(bar)))
        bar.debugDragPill(toViewportX: bar.debugViewportWidth - 4)
        let held = bar.debugStripOffset
        for _ in 0..<20 { bar.debugStepEdgeScroll() }
        #expect(bar.debugStripOffset > held)
    }

    /// And it stops at the end of the content rather than scrolling into
    /// nothing.
    @Test func theEndOfTheStripIsTheEndOfTheScroll() {
        let bar = bar(Self.five, width: 260)
        #expect(bar.debugBeginPillDrag(atViewportX: pillCentre(bar)))
        bar.debugDragPill(toViewportX: bar.debugViewportWidth - 1)
        for _ in 0..<400 { bar.debugStepEdgeScroll() }
        #expect(abs(bar.debugStripOffset - bar.debugOverflow) < 1)
    }

    /// A finger in the middle of the capsule moves nothing by itself — the
    /// end-of-strip scroll is about the ENDS, and a drag across a crowded strip
    /// must not creep.
    @Test func holdingInTheMiddleScrollsNothing() {
        let bar = bar(Self.five, width: 260)
        #expect(bar.debugBeginPillDrag(atViewportX: pillCentre(bar)))
        bar.debugDragPill(toViewportX: bar.debugViewportWidth / 2)
        let held = bar.debugStripOffset
        for _ in 0..<20 { bar.debugStepEdgeScroll() }
        #expect(bar.debugStripOffset == held)
    }

    /// The pages keep up with a strip that is scrolling under a still finger:
    /// the grip is unchanged and there is new content beneath it, so the pill —
    /// and what it reports — advances.
    @Test func theStripScrollingAdvancesThePages() {
        let bar = bar(Self.five, width: 260)
        var reported: [CGFloat] = []
        bar.onScrub = { reported.append($0) }
        #expect(bar.debugBeginPillDrag(atViewportX: pillCentre(bar)))
        bar.debugDragPill(toViewportX: bar.debugViewportWidth - 4)
        let atEdge = reported.last ?? 0
        for _ in 0..<20 { bar.debugStepEdgeScroll() }
        #expect((reported.last ?? 0) > atEdge)
    }

    /// A strip with room to spare has nothing to scroll, and holding at its
    /// edge must not invent any.
    @Test func aStripThatFitsNeverScrolls() {
        let bar = bar()
        #expect(bar.debugOverflow <= 0.5)
        #expect(bar.debugBeginPillDrag(atViewportX: pillCentre(bar)))
        bar.debugDragPill(toViewportX: bar.debugViewportWidth - 2)
        for _ in 0..<20 { bar.debugStepEdgeScroll() }
        #expect(bar.debugStripOffset == 0)
    }
}
