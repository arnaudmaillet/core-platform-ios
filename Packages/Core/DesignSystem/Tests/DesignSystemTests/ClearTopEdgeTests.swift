import Testing
import UIKit
@testable import DesignSystem

/// `prefersClearTopEdge()` hides the TOP edge effect and nothing else. The
/// screens that call it are pinned in their own packages; this pins what the
/// call itself does.
@MainActor
struct ClearTopEdgeTests {
    @Test func theTopEdgeEffectIsHidden() {
        let scrollView = UIScrollView()
        scrollView.prefersClearTopEdge()
        #expect(scrollView.topEdgeEffect.isHidden)
    }

    /// The premise the other tests rest on: a fresh scroll view SHOWS its
    /// effect, so asserting it is hidden after the call proves the call did
    /// something.
    @Test func theDefaultShowsTheEffect() {
        let scrollView = UIScrollView()
        #expect(!scrollView.topEdgeEffect.isHidden)
    }

    /// Only the top. The bottom edge — above a tab bar, a toolbar, a composer —
    /// is not what the call is about, and keeps the system's effect.
    @Test func theBottomEdgeKeepsTheSystemsEffect() {
        let scrollView = UIScrollView()
        scrollView.prefersClearTopEdge()
        #expect(!scrollView.bottomEdgeEffect.isHidden)
        #expect(scrollView.bottomEdgeEffect.style == .automatic)
    }

    /// The extension is on `UIScrollView`, so its subclasses — which is every
    /// list in the app — get it without a cast.
    @Test func itReachesTablesAndCollectionViews() {
        let table = UITableView(frame: .zero, style: .plain)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        table.prefersClearTopEdge()
        collection.prefersClearTopEdge()
        #expect(table.topEdgeEffect.isHidden)
        #expect(collection.topEdgeEffect.isHidden)
    }
}

/// ⚠️ The pager needs it as well as its pages: its own scroll view spans the
/// header and draws its own effect, so pages alone leave the band in place.
@MainActor
struct HorizontalPagerClearTopEdgeTests {
    @Test func aPagerHidesItsTopEdgeEffect() {
        let pager = HorizontalPagerView(pages: [UIView(), UIView()])
        #expect(pager.pagingScrollView.topEdgeEffect.isHidden)
    }

    /// The media picker's opt-out must really leave the effect alone, or the
    /// parameter is one that does nothing.
    @Test func aPagerThatOptsOutLeavesTheEffectAlone() {
        let pager = HorizontalPagerView(pages: [UIView(), UIView()], prefersClearTopEdge: false)
        #expect(!pager.pagingScrollView.topEdgeEffect.isHidden)
    }
}
