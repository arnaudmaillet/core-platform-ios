import Testing
import UIKit
@testable import DesignSystem

/// The two shapes one selector wears.
///
/// A `.navigationTitle` bar hugs its titles, because a navigation bar hands it
/// only what the side items leave. The SAME instance is hosted inline on the
/// profile, where it has the page's whole column and hugging leaves a short
/// capsule stranded in the middle of it — so it is told to fill, and it narrows
/// back to its hugged size as it approaches the bar it docks into.
///
/// Every failure here still renders a plausible-looking bar, which is why these
/// are measurements rather than screenshots: a fill that only changed the
/// DISTRIBUTION and left the row centred looks like a correctly-sized capsule
/// with its segments bunched in the middle, and a floor taken from the wrong
/// arrangement looks like a bar that truncates a title for the last frame
/// before it docks.
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

    // MARK: - The morph's floor

    /// ⚠️ **The floor follows the arrangement the bar is IN, not the one it is
    /// going to.** A filled bar sizes every segment to the widest, so its
    /// narrowest honest width is widest × count — wider than the sum of each
    /// that the docked bar hugs to. A morph aimed at the docked number instead
    /// spends its last frames squeezing the longest title below what it needs,
    /// and these segments' minimums are breakable by design, so it truncates
    /// rather than refuses.
    @Test func theFloorIsWiderFilledThanHugged() {
        let filled = bar(width: 360, fills: true)
        let hugging = bar(width: 360, fills: false)
        #expect(filled.naturalWidth > hugging.naturalWidth)
    }

    /// And at that floor every segment is still at least as wide as the widest
    /// title needs — which is the whole claim the floor makes.
    @Test func atItsFloorAFilledBarStillFitsTheWidestTitle() {
        let widest = segmentFrames(bar(width: 360, fills: false)).map(\.width).max() ?? 0
        let atFloor = bar(width: 360, fills: true)
        let squeezed = bar(width: atFloor.naturalWidth, fills: true)
        for frame in segmentFrames(squeezed) {
            #expect(frame.width + 0.5 >= widest, "\(frame.width) is under \(widest)")
        }
    }

    /// The floor is a floor, not a resting size: at rest the bar is as wide as
    /// the column it was given.
    @Test func aFilledBarIsWiderThanItsFloorAtRest() {
        let filled = bar(width: 360, fills: true)
        #expect(filled.naturalWidth < 360)
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
