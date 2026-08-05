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
    private func bar(_ titles: [String], crowded: Bool, slot: CGFloat) -> PagedTabBar {
        let bar = PagedTabBar(titles: titles, style: .navigationTitle)
        bar.scrollsWhenCrowded = crowded
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
        let bar = bar(Self.five, crowded: true, slot: 258)
        #expect(bar.debugOverflow > 0)
    }

    /// And left alone it does not: the two screens whose bars already fit keep
    /// the arrangement measured for them, where the shortfall lands on a title
    /// rather than on the trailing edge.
    @Test func aSnugBarNeverOverflows() {
        let bar = bar(Self.five, crowded: false, slot: 258)
        #expect(bar.debugOverflow <= 0.5)
    }

    /// ⚠️ Crowding is only ever about not fitting. A bar with room to spare
    /// must not start scrolling because the flag is on — the overflow is a
    /// consequence of the titles, not of the mode.
    @Test func aCrowdedBarWithRoomToSpareStillDoesNotScroll() {
        let bar = bar(Self.three, crowded: true, slot: 320)
        #expect(bar.debugOverflow <= 0.5)
    }

    /// Every tab stays reachable rather than being cropped: the strip's own
    /// width covers all five segments at their natural sizes.
    @Test func everyTabKeepsItsWidthWhenCrowded() {
        let crowded = bar(Self.five, crowded: true, slot: 258)
        let roomy = bar(Self.five, crowded: true, slot: 600)
        // The same five segments, whatever slot they were handed.
        #expect(abs(crowded.intrinsicContentSize.width - roomy.intrinsicContentSize.width) < 1)
    }

    /// The mode is reversible — nothing about it is baked in at init.
    @Test func crowdingCanBeTurnedBackOff() {
        let bar = bar(Self.five, crowded: true, slot: 258)
        bar.scrollsWhenCrowded = false
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(bar.debugOverflow <= 0.5)
    }
}
