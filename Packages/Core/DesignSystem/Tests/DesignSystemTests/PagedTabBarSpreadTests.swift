import Testing
import UIKit
@testable import DesignSystem

/// A bar told to give way when crowded (`.naturalWhenCrowded`, the docked
/// accessory's setting): equal slots when they fit, the naturals SPREAD across
/// the glass when only they fit, a centred scrolling strip when nothing fits.
@MainActor
struct PagedTabBarSpreadTests {
    /// Titles whose equal slots overrun a docked accessory while their
    /// naturals do not — For You's pair, with a badge on the second.
    private func bar(width: CGFloat) -> PagedTabBar {
        let bar = PagedTabBar(titles: ["Discover", "Following"], style: .navigationTitle)
        bar.fillsWidth = true
        bar.segmentSizing = .naturalWhenCrowded
        bar.setBadge(.count(8), at: 1)
        bar.frame = CGRect(x: 0, y: 0, width: width, height: PagedTabBar.Style.navigationTitle.height)
        bar.layoutIfNeeded()
        return bar
    }

    /// A width between the two thresholds, read off the bar itself: wider
    /// than the naturals, narrower than two slots of the widest.
    private func midwayWidth(of bar: PagedTabBar) -> CGFloat {
        let natural = bar.debugSegmentNaturalWidths
        let naturals = natural.reduce(0, +)
        let slots = (natural.max() ?? 0) * CGFloat(natural.count)
        return ((naturals + slots) / 2).rounded()
    }

    @Test func naturalsThatFitAreSpreadAcrossTheGlassWithEqualAir() {
        let bar = bar(width: 360)
        let width = midwayWidth(of: bar)
        bar.frame.size.width = width
        bar.layoutIfNeeded()
        #expect(bar.debugRowArrangement == "naturalsSpread", "at \(width): \(bar.debugRowArrangement), naturals \(bar.debugSegmentNaturalWidths)")
        let frames = bar.debugSegmentFrames
        #expect(frames.count == 2)
        #expect(abs(frames[0].minX) < 0.5, "the row starts at the glass's edge: \(frames[0])")
        #expect(abs(frames[1].maxX - width) < 0.5, "and ends at it: \(frames[1].maxX) vs \(width)")
        #expect(abs(bar.debugContentWidth - width) < 0.5, "nothing to scroll: the content is the glass, \(bar.debugContentWidth)")
        // Each segment took the same share of the slack: their widths differ
        // by exactly what their titles differ by.
        let natural = bar.debugSegmentNaturalWidths
        let extra0 = frames[0].width - natural[0], extra1 = frames[1].width - natural[1]
        #expect(extra0 > 1 && abs(extra0 - extra1) < 0.5, "equal shares: \(extra0) and \(extra1)")
    }

    @Test func equalSlotsWinWhenTheyFit() {
        let bar = bar(width: 360)
        #expect(bar.debugRowArrangement == "equalSlots")
        let frames = bar.debugSegmentFrames
        #expect(abs(frames[0].width - frames[1].width) < 0.5)
    }

    @Test func naturalsThatDoNotFitHugAndScroll() {
        let bar = bar(width: 360)
        let width = (bar.debugSegmentNaturalWidths.reduce(0, +) - 20).rounded()
        bar.frame.size.width = width
        bar.layoutIfNeeded()
        #expect(bar.debugRowArrangement == "naturalsHug", "at \(width): \(bar.debugRowArrangement)")
        #expect(bar.debugContentWidth > width + 0.5, "the strip out-measures the glass and scrolls: \(bar.debugContentWidth) vs \(width)")
    }
}
