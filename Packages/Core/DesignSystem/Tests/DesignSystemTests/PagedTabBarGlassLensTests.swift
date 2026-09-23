import Testing
import UIKit
@testable import DesignSystem

/// The selection pill as Liquid Glass while it moves — a SPIKE behind
/// `-selector-glass-lens`, and these are the tests of its one rule: the pill
/// is glass exactly while it is held or travelling, and tint once it lands.
///
/// Whether the glass RENDERS acceptably on each host is a screenshot's
/// question, not this suite's; this covers the state machine that decides
/// when it is asked to.
@MainActor
struct PagedTabBarGlassLensTests {
    private func bar(lifts: Bool = true) -> PagedTabBar {
        let bar = PagedTabBar(titles: ["Activity", "Gallery", "Short"], style: .floating)
        bar.liftsLensAsGlass = lifts
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: PagedTabBar.Style.floating.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    @Test func aTapLiftsThePillUntilItsTargetLands() {
        let bar = bar()
        #expect(!bar.debugLensIsGlass, "guard: tint at rest")

        bar.debugSimulateTap(at: 2)
        #expect(bar.debugLensIsGlass, "a tap sends the pill travelling as glass")

        bar.setProgress(0.5)
        bar.setProgress(1)
        #expect(bar.debugLensIsGlass, "a whole page on the way is not the landing")

        bar.setProgress(2)
        #expect(bar.debugLensIsGlass, "the pages landed; the glass pill is still on its way")
        bar.debugRunLensSpringToRest()
        #expect(!bar.debugLensIsGlass, "arrived, so tint")
    }

    @Test func aGrabLiftsThePillAndAReleaseWithoutTravelSettlesIt() {
        let bar = bar()
        let pill = bar.debugPillInViewport.midX

        #expect(bar.debugBeginPillDrag(atViewportX: pill))
        #expect(bar.debugLensIsGlass, "held, so glass")

        bar.debugEndPillDrag()
        #expect(!bar.debugLensIsGlass, "a press that never travelled is a tap, and lands at once")
    }

    @Test func aReleaseAfterTravelStaysGlassUntilThePagesLand() {
        let bar = bar()
        let pill = bar.debugPillInViewport.midX
        var released: CGFloat?
        bar.onScrubEnd = { released = $0 }

        #expect(bar.debugBeginPillDrag(atViewportX: pill))
        bar.debugDragPill(toViewportX: pill + 60)
        bar.debugEndPillDrag()
        #expect(released != nil, "guard: the pager was handed the release")
        #expect(bar.debugLensIsGlass, "the pages have not landed yet")

        bar.setProgress(0.7)
        #expect(bar.debugLensIsGlass, "still travelling")
        bar.setProgress(1)
        bar.debugRunLensSpringToRest()
        #expect(!bar.debugLensIsGlass, "any whole page is the landing after a release")
    }

    @Test func theGlassOverlaySitsOnTheTintedPill() {
        let bar = bar()
        bar.debugSimulateTap(at: 1)
        bar.layoutIfNeeded()
        guard let glass = bar.debugGlassLensFrame else {
            Issue.record("no glass overlay while lifted")
            return
        }
        let tint = bar.debugPillInViewport
        #expect(abs(glass.midX - tint.midX) < 0.5 && abs(glass.midY - tint.midY) < 0.5,
                "glass \(glass) over tint \(tint)")
    }

    @Test func nothingLiftsUnlessAskedFor() {
        let bar = bar(lifts: false)
        bar.debugSimulateTap(at: 2)
        #expect(!bar.debugLensIsGlass)
        #expect(bar.debugBeginPillDrag(atViewportX: bar.debugPillInViewport.midX))
        #expect(!bar.debugLensIsGlass)
        #expect(bar.debugGlassLensFrame == nil)
    }
}

/// The lens's optics: while lifted the strip's real titles are cut out under
/// the lens and its refracted copy shows in their place; once settled the
/// titles come back and the copy goes.
@MainActor
struct PagedTabBarLensOpticsTests {
    @Test func aLiftedLensMasksTheTitlesAndShowsItsCopyUntilItSettles() async {
        guard LensRefractor.shared.device != nil else {
            Issue.record("no Metal device in this test host")
            return
        }
        await LensRefractor.shared.ready()
        let bar = PagedTabBar(titles: ["Activity", "Gallery", "Short"], style: .floating)
        bar.liftsLensAsGlass = true
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: PagedTabBar.Style.floating.height)
        bar.layoutIfNeeded()
        #expect(!bar.debugLensMasksTitles && !bar.debugLensCopyIsShowing, "guard: plain strip at rest")

        bar.debugSimulateTap(at: 2)
        bar.debugRunLensSpringToRest()
        #expect(bar.debugLensIsGlass, "guard: travelling, the target has not landed")
        #expect(bar.debugLensMasksTitles, "the real titles are cut out under the lens")
        #expect(bar.debugLensCopyIsShowing, "the refracted copy stands in for them")

        bar.setProgress(2)
        bar.debugRunLensSpringToRest()
        #expect(!bar.debugLensIsGlass, "guard: landed and settling")
        #expect(bar.debugLensMasksTitles, "the copy eases out over the settle; the titles stay cut until it ends")
        bar.debugFinishLensSettle()
        #expect(!bar.debugLensMasksTitles, "settled: the real titles are back")
        #expect(!bar.debugLensCopyIsShowing, "settled: no copy")
    }
}
