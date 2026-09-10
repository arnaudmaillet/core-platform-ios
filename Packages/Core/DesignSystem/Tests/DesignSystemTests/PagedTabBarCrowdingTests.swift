import Testing
import UIKit
@testable import DesignSystem

/// What a hugging bar does when its titles do not fit.
///
/// Normally it truncates: a title view gets only what the side buttons leave,
/// and a strip that scrolled out from between them could hide a tab with
/// nothing to say so. That holds while the shortfall is a few points. It stops
/// holding at five tabs, where the titles want 317pt of a slot the navigation
/// bar caps at 258 — something is hidden whatever the bar does, and hiding a
/// tab REACHABLY beats hiding it permanently.
@MainActor
struct PagedTabBarCrowdingTests {
    private static let five = ["Activity", "Gallery", "Short", "Saved", "Reactions"]
    private static let three = ["Activity", "Gallery", "Short"]

    /// Laid out in a slot too narrow for it, the way the navigation bar hands
    /// one over.
    private func bar(_ titles: [String], slot: CGFloat) -> PagedTabBar {
        let bar = PagedTabBar(titles: titles, style: .navigationTitle)
        bar.frame = CGRect(x: 0, y: 0, width: slot, height: PagedTabBar.Style.navigationTitle.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    /// The measurement the whole decision rests on: five titles do not fit.
    @Test func fiveTitlesOutgrowTheNavigationBarsSlot() {
        let bar = PagedTabBar(titles: Self.five, style: .navigationTitle)
        // 258 is the cap the bar imposes however much more is asked for.
        #expect(bar.intrinsicContentSize.width > 258)
    }

    /// ⚠️ Crowded, the strip out-measures the capsule — which is what gives the
    /// scroll view something to scroll. Without this the row is squeezed to the
    /// slot and the titles clip instead.
    @Test func aCrowdedBarOverflowsItsCapsule() {
        let bar = bar(Self.five, slot: 258)
        #expect(bar.debugOverflow > 0)
    }

    /// ⚠️ Crowding is only ever about not fitting. A bar with room to spare
    /// must not start scrolling because the flag is on — the overflow is a
    /// consequence of the titles, not of the mode.
    @Test func aCrowdedBarWithRoomToSpareStillDoesNotScroll() {
        let bar = bar(Self.three, slot: 320)
        #expect(bar.debugOverflow <= 0.5)
    }

    /// Every tab stays reachable rather than being cropped: the strip's own
    /// width covers all five segments at their natural sizes.
    @Test func everyTabKeepsItsWidthWhenCrowded() {
        let crowded = bar(Self.five, slot: 258)
        let roomy = bar(Self.five, slot: 600)
        // The same five segments, whatever slot they were handed.
        #expect(abs(crowded.intrinsicContentSize.width - roomy.intrinsicContentSize.width) < 1)
    }

    /// ⚠️ **The floating bar behaves the same way**, which is the point of
    /// "unified": one component with one answer to not fitting, rather than a
    /// rule per host. It always could scroll; what changed is that the other
    /// host stopped being the exception.
    @Test func aFloatingBarCrowdsTheSameWay() {
        let bar = PagedTabBar(titles: Self.five, style: .floating)
        bar.frame = CGRect(x: 0, y: 0, width: 200, height: PagedTabBar.Style.floating.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(bar.debugOverflow > 0)
    }

    /// And no title is ever truncated to make room — the segments keep the
    /// widths they asked for and the strip carries the shortfall.
    @Test func theTitlesKeepTheirWidthsRatherThanClipping() {
        let narrow = bar(Self.five, slot: 200)
        let wide = bar(Self.five, slot: 600)
        #expect(abs(narrow.intrinsicContentSize.width - wide.intrinsicContentSize.width) < 1)
    }
}
/// The gestures this bar has, and which one a finger gets.
///
/// Three drivers share one control, and the whole design is that WHERE the
/// touch lands decides: on the selection pill it drags the pill, anywhere else
/// on the capsule it scrolls the strip, and a press that does not travel is a
/// tap. That rule replaced an earlier drag which could be grabbed anywhere and
/// therefore had to stand down whenever the strip could scroll — the same
/// finger on the same control meaning different things at three tabs and at
/// five. None of this is something a screenshot shows.
@MainActor
struct PagedTabBarGestureTests {
    private func bar(_ titles: [String], style: PagedTabBar.Style) -> PagedTabBar {
        let bar = PagedTabBar(titles: titles, style: style)
        bar.frame = CGRect(origin: .zero, size: CGSize(width: 258, height: style.height))
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    /// ⚠️ **The bar adds exactly ONE recognizer, and no pan lives anywhere in
    /// its subtree but the scroll view's own.**
    ///
    /// The subtree is what is walked, not `bar.gestureRecognizers` — the test
    /// this replaces filtered the bar's own list for a pan, and the pan it
    /// existed to forbid was attached to `capsule.contentView`, one level down.
    /// It could never have failed.
    @Test(arguments: [PagedTabBar.Style.floating, .navigationTitle])
    func theOnlyGrabIsTheOneOnThePill(style: PagedTabBar.Style) {
        let bar = bar(["Activity", "Gallery", "Short"], style: style)
        var pans: [UIPanGestureRecognizer] = []
        var presses: [UILongPressGestureRecognizer] = []
        func walk(_ view: UIView) {
            for recognizer in view.gestureRecognizers ?? [] {
                if let pan = recognizer as? UIPanGestureRecognizer { pans.append(pan) }
                if let press = recognizer as? UILongPressGestureRecognizer { presses.append(press) }
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        // The strip's own, and nothing else's.
        #expect(pans.allSatisfy { $0.view is UIScrollView })
        // The grab: exactly one on the bar itself, beginning on touch-down.
        // (The segments are `UIButton`s and UIKit gives each of them long
        // presses of its own — those are not ours and are counted out by asking
        // whose view they are on.)
        let grabs = presses.filter { $0.view === bar }
        #expect(grabs.count == 1)
        #expect(grabs.first?.minimumPressDuration == 0)
        // ⚠️ It must not cancel touches in view, or the segment under it never
        // sees the tap and `onReselect` dies with it.
        #expect(grabs.first?.cancelsTouchesInView == false)
    }

    /// Tapping is how a tab is chosen, and it still is: the selection moves and
    /// announces itself.
    @Test func tappingASegmentStillChangesTheTab() {
        let bar = bar(["Activity", "Gallery", "Short"], style: .navigationTitle)
        var changed: [Int] = []
        bar.addAction(UIAction { [weak bar] _ in changed.append(bar?.selectedIndex ?? -1) },
                      for: .valueChanged)
        bar.select(2)
        #expect(changed == [2])
    }

    /// And the pages still drive the lens, which is the other half of "tap or
    /// swipe" — a swipe reports progress and the lens follows it.
    @Test func thePagesStillDriveTheLens() {
        let bar = bar(["Activity", "Gallery", "Short"], style: .navigationTitle)
        bar.setProgress(2)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(bar.selectedIndex == 2)
    }
}

/// Who gets to decide where a crowded strip is scrolled to.
///
/// Two things want to move it: the selection, which should bring itself into
/// view when it changes, and the viewer, who drags the strip to reach a tab
/// they cannot see. The second is the one that breaks if the first is written
/// carelessly — chasing the lens on every layout pass means a hand-made scroll
/// is undone before the finger can reach what it scrolled to.
@MainActor
struct PagedTabBarStripScrollTests {
    private func crowdedBar() -> PagedTabBar {
        let bar = PagedTabBar(
            titles: ["Activity", "Gallery", "Short", "Saved", "Liked"], style: .navigationTitle
        )
        bar.frame = CGRect(x: 0, y: 0, width: 258, height: PagedTabBar.Style.navigationTitle.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    /// A selection that moves brings itself into view — the half that has to
    /// keep working.
    ///
    /// Driven through `setProgress`, because that is what actually moves the
    /// lens: the pages report their position every frame and the lens follows
    /// them, so a bare `select` changes which segment is reported without
    /// moving anything until the pager catches up.
    @Test func changingTheSelectionScrollsItIntoView() {
        let bar = crowdedBar()
        let before = bar.debugStripOffset
        bar.setProgress(4)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(bar.debugStripOffset > before)
    }

    /// ⚠️ **A scroll the viewer made survives a layout pass.** This is the bug
    /// the follow-on-every-pass version had: drag the strip to see a hidden
    /// tab, and the next pass — a badge, a re-render, anything — puts it back
    /// where the selection is, before the tab can be tapped.
    @Test func aHandMadeScrollSurvivesRelayout() {
        let bar = crowdedBar()
        bar.debugSetStripOffset(30)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(abs(bar.debugStripOffset - 30) < 0.5)
    }

    /// And it survives the many passes a real screen produces, not just one.
    @Test func aHandMadeScrollSurvivesRepeatedRelayout() {
        let bar = crowdedBar()
        bar.debugSetStripOffset(25)
        for _ in 0..<5 {
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
        }
        #expect(abs(bar.debugStripOffset - 25) < 0.5)
    }

    /// ⚠️ But a selection change still wins over it. Scrolling away and then
    /// choosing a tab must go to that tab — otherwise the strip is stuck where
    /// it was left and the selected tab can be off screen.
    @Test func aSelectionChangeOverridesAHandMadeScroll() {
        let bar = crowdedBar()
        bar.setProgress(4)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        // The viewer drags back to the start, then chooses the first tab.
        bar.debugSetStripOffset(20)
        bar.setProgress(0)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(abs(bar.debugStripOffset) < 0.5)
    }

    /// ⚠️ **A bar CAPPED after it was already laid out still reveals its
    /// selection**, and this is the one the profile's docked selector failed.
    ///
    /// A leading bar item is sized twice: once at the bar's intrinsic width,
    /// where the strip fits and there is nothing to reveal, and again when the
    /// host's ceiling caps it, where it overflows. The bar decided "nothing to
    /// scroll" on the FIRST of those and never asked again — it read the scroll
    /// view's bounds from its own `layoutSubviews`, which runs before the scroll
    /// view has been resized, so it was measuring a viewport it had already
    /// stopped having. Measured on iPhone SE 3: `capsule=149` while
    /// `scroller=198`, and "Short" sat clipped outside a capsule showing
    /// "Activity Gallery" for the life of the screen.
    ///
    /// ⚠️ This pins the half a test CAN hold — that a cap arriving after the
    /// first layout still reveals the selection. It does not reproduce the
    /// stale-bounds half: `layoutIfNeeded()` settles the whole tree, so the
    /// test always gets the extra pass the real screen never had. That half is
    /// held by `StripScrollView.onLayout` and was proved in the simulator.
    @Test func aBarCappedAfterLayoutStillRevealsItsSelection() {
        let bar = PagedTabBar(titles: ["Activity", "Gallery", "Short"], style: .navigationTitle)
        // First pass: its own intrinsic width, where everything fits.
        bar.frame = CGRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        bar.setProgress(2)
        bar.layoutIfNeeded()
        #expect(abs(bar.debugStripOffset) < 0.5, "nothing to reveal while it fits")

        // Second pass: the host caps it, as a bar-item host used to.
        bar.frame.size.width = bar.intrinsicContentSize.width - 50
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(bar.debugOverflow > 0, "the cap has to make it overflow, or the test proves nothing")
        #expect(bar.debugStripOffset > 0, "the selected tab was never scrolled into view")
    }

    /// ⚠️ **Docked, undocked, docked again — the selection is revealed EVERY
    /// time**, and this is the one a real finger found that a programmatic jump
    /// to the dock line did not.
    ///
    /// The profile's selector is capped at 149pt while docked and sits at 198
    /// while not. Revealing at 149 puts the strip at its offset correctly; the
    /// undock then grows the viewport to 198, where the strip no longer
    /// overflows, so UIKit clamps that offset back to zero. Re-docking returns
    /// the viewport to 149 — and a rule that remembered "already revealed at
    /// 149" skipped it, protecting an offset that had been thrown away two
    /// passes earlier. Measured end to end with `-header-dock-demo`, and the
    /// screen showed "Activity Gallery" with the selected tab clipped off.
    ///
    /// ⚠️ Like its neighbour above, this pins the INTENT rather than the exact
    /// failure: `layoutIfNeeded()` settles the tree and never reproduces the
    /// clamp UIKit applies when the viewport grows past the content. What
    /// actually proved it was a real CGEvent drag on an iPhone SE 3.
    @Test func aSelectionSurvivesDockingUndockingAndDockingAgain() {
        let titles = ["Activity", "Gallery", "Short"]
        let bar = PagedTabBar(titles: titles, style: .navigationTitle)
        let loose = bar.intrinsicContentSize.width
        let docked = loose - 50

        func layOut(at width: CGFloat) {
            bar.frame = CGRect(x: 0, y: 0, width: width, height: PagedTabBar.Style.navigationTitle.height)
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
        }

        layOut(at: loose)
        bar.setProgress(2)
        bar.layoutIfNeeded()

        layOut(at: docked)
        #expect(bar.debugStripOffset > 0, "first dock never revealed the selection")

        layOut(at: loose)
        layOut(at: docked)
        #expect(bar.debugStripOffset > 0, "the second dock left the selection off screen")
    }

    /// A bar with room to spare has nothing to scroll and stays put.
    @Test func aBarThatFitsNeverScrolls() {
        let bar = PagedTabBar(titles: ["All", "Requests"], style: .navigationTitle)
        bar.frame = CGRect(x: 0, y: 0, width: 320, height: PagedTabBar.Style.navigationTitle.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        bar.setProgress(1)
        bar.layoutIfNeeded()
        #expect(abs(bar.debugStripOffset) < 0.5)
    }
}
