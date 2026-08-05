import Testing
import UIKit
@testable import DesignSystem

/// The two shapes this selector wears.
///
/// A `.navigationTitle` bar hugs its titles, because a navigation bar hands it
/// only what the side items leave. The same bar is hosted inline on the profile,
/// where it has the page's whole column and hugging leaves a short capsule
/// stranded in the middle of it — so that one is told to FILL, while its twin in
/// the navigation slot goes on hugging.
///
/// Every failure here still renders a plausible-looking bar, which is why these
/// are measurements rather than screenshots: a fill that only changed the
/// DISTRIBUTION and left the row centred looks like a correctly-sized capsule
/// with its segments bunched in the middle.
@MainActor
struct PagedTabBarFillTests {
    private static let titles = ["Activity", "Gallery", "Short"]

    /// Laid out at a stated width, the way a host's own constraint sizes it.
    private func bar(width: CGFloat, fills: Bool) -> PagedTabBar {
        let bar = PagedTabBar(titles: Self.titles, style: .navigationTitle)
        bar.fillsWidth = fills
        bar.frame = CGRect(
            x: 0, y: 0, width: width, height: PagedTabBar.Style.navigationTitle.height
        )
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    /// Every segment's frame, taken one selection at a time — the lens reports
    /// the segment it is framing, and it is the only window onto the row.
    private func segmentFrames(_ bar: PagedTabBar) -> [CGRect] {
        Self.titles.indices.compactMap { index in
            bar.select(index)
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            return bar.debugLensAlignment?.segment
        }
    }

    // MARK: - Filling

    /// A filled bar stops stating a width: its host owns that number, and an
    /// intrinsic one would argue with the constraint the host sets.
    @Test func aFilledBarTakesTheWidthItIsGiven() {
        let filled = bar(width: 360, fills: true)
        #expect(filled.intrinsicContentSize.width == UIView.noIntrinsicMetric)

        // And the hugging bar still states one — this is what a navigation bar
        // sizes the title slot from, so losing it would empty the slot.
        let hugging = bar(width: 360, fills: false)
        #expect(hugging.intrinsicContentSize.width > 0)
    }

    /// Filled, the segments split the column evenly — a short title gets the
    /// same target as a long one, which is what makes a full-width bar read as
    /// one balanced control.
    @Test func aFilledBarDividesTheColumnEqually() {
        let frames = segmentFrames(bar(width: 360, fills: true))
        #expect(frames.count == 3)
        let widths = frames.map(\.width)
        guard let smallest = widths.min(), let largest = widths.max() else { return }
        #expect(largest - smallest < 0.5, "segments came back uneven: \(widths)")
    }

    /// ⚠️ **The extra room has to reach the SEGMENTS.** A hugging bar centres
    /// its row between the capsule's ends, and a fill that changed only the
    /// distribution would leave the row at its natural total with the slack
    /// split as margin either side — three bunched segments inside a wide
    /// capsule, which looks deliberate enough to ship.
    @Test func aFilledBarSpreadsAcrossTheWholeCapsule() {
        let width: CGFloat = 360
        let frames = segmentFrames(bar(width: width, fills: true))
        guard let first = frames.first, let last = frames.last else {
            Issue.record("the bar reported no segments")
            return
        }
        // Both ends within the capsule's own padding of the capsule's edges.
        let padding: CGFloat = 8
        #expect(first.minX <= padding)
        #expect(last.maxX >= width - padding)
    }

    /// Hugging, each title keeps its own width — the property that stops one
    /// long title inflating all three inside a navigation bar's slot.
    @Test func aHuggingBarKeepsEachTitlesOwnWidth() {
        let widths = segmentFrames(bar(width: 360, fills: false)).map(\.width)
        guard let smallest = widths.min(), let largest = widths.max() else { return }
        #expect(largest - smallest > 0.5, "segments came back equal: \(widths)")
    }

    // MARK: - Going back

    /// Docking hands the bar back to the navigation bar, which sizes the slot
    /// from the intrinsic width — so the fill has to come off completely, not
    /// just visually.
    @Test func unfillingRestoresTheHuggedShape() {
        let bar = bar(width: 360, fills: true)
        bar.fillsWidth = false
        bar.frame = CGRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()

        #expect(bar.intrinsicContentSize.width > 0)
        let widths = segmentFrames(bar).map(\.width)
        guard let smallest = widths.min(), let largest = widths.max() else { return }
        #expect(largest - smallest > 0.5, "segments stayed equal: \(widths)")
    }

    /// Filling is idempotent — the morph sets it on every undock, and a second
    /// application must not stack a second pair of pinning constraints on the
    /// row. Unsatisfiable constraints do not throw here; UIKit breaks one and
    /// carries on, so the symptom would be an intermittently misplaced row.
    @Test func fillingTwiceChangesNothing() {
        let bar = bar(width: 360, fills: true)
        let before = segmentFrames(bar).map(\.width)
        bar.fillsWidth = true
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(segmentFrames(bar).map(\.width) == before)
    }

    /// A floating bar already fills, and has no hugged shape to return to —
    /// asking it to fill is a no-op rather than a second arrangement.
    @Test func afloatingBarIsUnaffected() {
        let bar = PagedTabBar(titles: Self.titles, style: .floating)
        let before = bar.intrinsicContentSize
        bar.fillsWidth = true
        #expect(bar.intrinsicContentSize == before)
    }
}

/// Choosing a segment, and choosing the one already chosen.
///
/// These are two different requests and the bar keeps them apart: `.valueChanged`
/// is a CHANGE, and firing it for a value that did not change would make every
/// handler on every screen wearing this bar defensive about being told nothing
/// happened. Re-selection gets its own channel, which screens without an answer
/// for it simply never set.
@MainActor
struct PagedTabBarReselectionTests {
    private func laidOutBar() -> PagedTabBar {
        let bar = PagedTabBar(titles: ["Activity", "Gallery", "Short"], style: .navigationTitle)
        bar.frame = CGRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    /// ⚠️ **A programmatic selection to the SAME segment is not a
    /// re-selection**, and this caught the first cut of it. Setting a value to
    /// what it already is is a no-op; TAPPING the thing already chosen is an
    /// event, and only the second is a request. The profile mirrors every choice
    /// onto a second bar, so `select` to the current segment happens on ordinary
    /// tab changes — announcing those would scroll the list to the top every
    /// time the viewer merely changed tabs.
    @Test func settingTheSegmentAlreadySetAnnouncesNothing() {
        let bar = laidOutBar()
        var reselected: [Int] = []
        var changed = 0
        bar.onReselect = { reselected.append($0) }
        bar.addAction(UIAction { _ in changed += 1 }, for: .valueChanged)

        bar.select(0)
        #expect(reselected.isEmpty)
        #expect(changed == 0)
    }

    /// A real change still comes through the change channel, and only there.
    @Test func changingTheSegmentAnnouncesAChange() {
        let bar = laidOutBar()
        var reselected: [Int] = []
        var changed: [Int] = []
        bar.onReselect = { reselected.append($0) }
        bar.addAction(UIAction { [weak bar] _ in changed.append(bar?.selectedIndex ?? -1) },
                      for: .valueChanged)

        bar.select(2)
        #expect(changed == [2])
        #expect(reselected.isEmpty)
        #expect(bar.selectedIndex == 2)
    }

    /// And a bar with no answer for re-selection is unaffected by any of it —
    /// the other two screens wearing this bar never set the closure.
    @Test func aBarWithoutAReselectionHandlerIsUnbothered() {
        let bar = laidOutBar()
        bar.select(1)
        bar.select(1)
        #expect(bar.selectedIndex == 1)
    }
}
