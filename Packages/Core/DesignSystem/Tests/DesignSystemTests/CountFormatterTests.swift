import Testing
import UIKit
@testable import DesignSystem

/// The app's single count spelling. Every counter on every surface routes
/// through here, so these cases are the contract the profile header, the grid
/// cells, the row context and the segment titles all share.
@Suite("Count formatter")
struct CountFormatterTests {
    @Test("Counts below a thousand are printed as they are")
    func smallCounts() {
        #expect(CountFormatter.compactString(for: 0) == "0")
        #expect(CountFormatter.compactString(for: 1) == "1")
        #expect(CountFormatter.compactString(for: 42) == "42")
        #expect(CountFormatter.compactString(for: 450) == "450")
        #expect(CountFormatter.compactString(for: 999) == "999")
    }

    @Test("Thousands abbreviate to K")
    func thousands() {
        #expect(CountFormatter.compactString(for: 1_000) == "1K")
        #expect(CountFormatter.compactString(for: 1_100) == "1.1K")
        #expect(CountFormatter.compactString(for: 1_240) == "1.2K")
        #expect(CountFormatter.compactString(for: 12_500) == "12.5K")
        #expect(CountFormatter.compactString(for: 999_000) == "999K")
    }

    @Test("Millions abbreviate to M")
    func millions() {
        #expect(CountFormatter.compactString(for: 1_000_000) == "1M")
        #expect(CountFormatter.compactString(for: 1_500_000) == "1.5M")
        #expect(CountFormatter.compactString(for: 12_300_000) == "12.3M")
        #expect(CountFormatter.compactString(for: 1_000_000_000) == "1000M")
    }

    /// The rule the whole formatter exists to enforce. Rounding would let a
    /// profile with 1,999 followers advertise "2K" — a number it has not
    /// reached — so the fraction is truncated, never rounded up.
    @Test("Truncates rather than rounding, so a count is never overstated")
    func truncatesRatherThanRounding() {
        #expect(CountFormatter.compactString(for: 1_999) == "1.9K")
        #expect(CountFormatter.compactString(for: 1_990) == "1.9K")
        #expect(CountFormatter.compactString(for: 1_099) == "1K")
        #expect(CountFormatter.compactString(for: 999_999) == "999.9K")
        #expect(CountFormatter.compactString(for: 1_999_999) == "1.9M")
    }

    /// The boundaries either side of each threshold, where an off-by-one in
    /// the switch would show up as "1000" instead of "1K".
    @Test("Threshold boundaries")
    func boundaries() {
        #expect(CountFormatter.compactString(for: 999) == "999")
        #expect(CountFormatter.compactString(for: 1_000) == "1K")
        #expect(CountFormatter.compactString(for: 999_999) == "999.9K")
        #expect(CountFormatter.compactString(for: 1_000_000) == "1M")
    }

    /// Counts should never be negative, but the formatter is handed `Int64`
    /// from the wire and must not produce nonsense if one arrives. Truncation
    /// is toward zero, so the magnitude shown is never larger than the real one.
    @Test("Negatives keep their sign and never grow in magnitude")
    func negatives() {
        #expect(CountFormatter.compactString(for: -5) == "-5")
        #expect(CountFormatter.compactString(for: -1_500) == "-1.5K")
        #expect(CountFormatter.compactString(for: -1_999) == "-1.9K")
        #expect(CountFormatter.compactString(for: -2_000_000) == "-2M")
    }

    @Test("The Int overload and the sugar agree with the Int64 one")
    func overloadsAgree() {
        #expect(CountFormatter.compactString(for: Int(1_240)) == "1.2K")
        #expect(1_240.formattedCompact() == "1.2K")
        #expect(Int64(1_500_000).formattedCompact() == "1.5M")
    }

    /// The reason this type exists: the row context used to carry its own
    /// abbreviation, and the grid cells another that rounded. Both now route
    /// here, and this pins them together.
    @Test("Row context spells counts the same way")
    func rowContextDelegates() {
        #expect(ProfileRowContext.followerCount(1_999).label == "1.9K followers")
        #expect(ProfileRowContext.followerCount(450).label == "450 followers")
    }
}

/// What a `.navigationTitle` bar does when its titles out-measure the slot.
///
/// ⚠️ **This is the question the profile's relationship lists turn on.** They
/// wear three counted titles ("12.4K Followers") in the navigation bar's title
/// view, which the bar caps — historically at 258pt. If overflow TRUNCATES
/// there, "12.4K Followers" and "200+ Following" collapse into two
/// indistinguishable stubs, which is the failure that drove the whole redesign.
///
/// The content width is pinned with `>=` against the scroller's frame, so the
/// strip is free to out-measure the capsule and scroll. Pinned here because the
/// alternative (`==`) is one character away and would silently restore
/// truncation — the type comment still describes a `scrollsWhenCrowded` picker
/// that no longer exists.
@MainActor
@Suite("Title-slot overflow")
struct PagedTabBarTitleOverflowTests {
    private func makeBar(_ titles: [String], width: CGFloat) -> PagedTabBar {
        let bar = PagedTabBar(titles: titles, style: .navigationTitle)
        // A navigation bar hands the title view a width; it does not promise
        // the one the view asked for. Squeezing it is the whole point.
        bar.frame = CGRect(x: 0, y: 0, width: width, height: 44)
        bar.layoutIfNeeded()
        return bar
    }

    @Test("Titles that fit produce no overflow")
    func fittingTitlesDoNotScroll() {
        // Short titles — the Messages inbox's shape. At 15pt three *counted*
        // titles no longer fit a 258pt slot, which is the whole reason the
        // strip has to scroll; see `crowdedTitlesScroll`.
        let bar = makeBar(["All", "Requests", "Suggestions"], width: 258)
        #expect(bar.debugOverflow == 0)
    }

    /// The relationship screen's own titles at the raised type size. They
    /// overflow a nominal slot, and that is the accepted trade: the counts stay
    /// whole and readable, and the strip slides.
    @Test("Counted relationship titles overflow at 15pt and stay whole")
    func countedRelationshipTitlesScroll() {
        let bar = makeBar(["35 Followers", "12 Following", "Friends"], width: 258)
        #expect(bar.debugOverflow > 0)
        #expect(bar.currentTitles == ["35 Followers", "12 Following", "Friends"])
    }

    /// The counts stay whole and the strip scrolls instead.
    @Test("Titles that do not fit overflow rather than truncate")
    func crowdedTitlesScroll() {
        let bar = makeBar(["12.4K Followers", "200+ Following", "1.2K Friends"], width: 258)
        #expect(bar.debugOverflow > 0)
        #expect(bar.currentTitles == ["12.4K Followers", "200+ Following", "1.2K Friends"])
    }

    /// Scrolled content is reachable — an overflow that cannot be scrolled to
    /// is just a clip with extra steps.
    @Test("The overflowed end can be scrolled into view")
    func overflowIsReachable() {
        let bar = makeBar(["12.4K Followers", "200+ Following", "1.2K Friends"], width: 258)
        let overflow = bar.debugOverflow

        bar.debugSetStripOffset(overflow)

        #expect(abs(bar.debugStripOffset - overflow) < 0.5)
    }
}

/// The app-wide scroll-indicator default.
///
/// ⚠️ **This suite exists because the mechanism is undocumented.** Neither
/// indicator property is marked `UI_APPEARANCE_SELECTOR`; `UIAppearance`
/// happens to replay them when a view enters a window. If a future iOS stops
/// doing that, every list in the app quietly grows scroll bars again — a
/// regression nobody would catch by reading code. These tests fail instead.
///
/// They attach to a real window on purpose: an appearance default is applied at
/// that moment, so a detached scroll view still reports `true` and asserting on
/// one would pass whether or not the mechanism works.
@MainActor
@Suite("Scroll indicator style")
struct ScrollIndicatorStyleTests {
    private func inWindow<V: UIView>(_ view: V) -> V {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(view)
        window.isHidden = false
        window.layoutIfNeeded()
        return view
    }

    @Test("A plain scroll view hides both indicators")
    func scrollViewHidesBoth() {
        ScrollIndicatorStyle.hideAppWide()
        let scroll = inWindow(UIScrollView())
        #expect(!scroll.showsVerticalScrollIndicator)
        #expect(!scroll.showsHorizontalScrollIndicator)
    }

    /// The subclass every list in the app is built from — it inherits the
    /// proxy, and that inheritance is the whole reason one default suffices.
    @Test("A collection view inherits the default")
    func collectionViewHidesBoth() {
        ScrollIndicatorStyle.hideAppWide()
        let collectionView = inWindow(
            UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        )
        #expect(!collectionView.showsVerticalScrollIndicator)
        #expect(!collectionView.showsHorizontalScrollIndicator)
    }

    /// ⚠️ **A table view inherits the VERTICAL default only.** It assigns
    /// `showsHorizontalScrollIndicator` to itself during init, and an instance
    /// value outranks an appearance default — so the global cannot reach it.
    /// Documented here as behaviour rather than worked around, because it is
    /// the reason the app's four table views set that one flag by hand. (No
    /// bar was ever visible: a table view does not scroll horizontally. The
    /// flag is set so the stated invariant is true, not to fix a symptom.)
    @Test("A table view inherits the vertical default but not the horizontal")
    func tableViewInheritsVerticalOnly() {
        ScrollIndicatorStyle.hideAppWide()
        let table = inWindow(UITableView(frame: .zero, style: .plain))
        #expect(!table.showsVerticalScrollIndicator)
        #expect(table.showsHorizontalScrollIndicator) // UIKit's own value wins
    }

    /// A screen that wants its bars back can still say so — an explicit value
    /// set on the instance outranks the appearance default.
    @Test("An explicit local value still wins")
    func explicitValueOverridesTheDefault() {
        ScrollIndicatorStyle.hideAppWide()
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = true
        _ = inWindow(scroll)
        #expect(scroll.showsVerticalScrollIndicator)
    }

    /// The tab strip is a scroll view too, and it must never show a bar under
    /// its glass — it was hiding its own before this default existed.
    @Test("The tab bar's strip hides its indicator")
    func pagedTabBarStripHidesIndicator() {
        ScrollIndicatorStyle.hideAppWide()
        let bar = PagedTabBar(titles: ["One", "Two", "Three"], style: .navigationTitle)
        bar.frame = CGRect(x: 0, y: 0, width: 200, height: 44)
        _ = inWindow(bar)
        let scrollers = bar.subviews.flatMap { $0.subviews }.compactMap { $0 as? UIScrollView }
            + bar.subviews.compactMap { $0 as? UIScrollView }
        #expect(scrollers.allSatisfy { !$0.showsHorizontalScrollIndicator })
    }
}
