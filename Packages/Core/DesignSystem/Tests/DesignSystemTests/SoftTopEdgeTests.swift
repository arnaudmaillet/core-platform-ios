import Testing
import UIKit
@testable import DesignSystem

/// `prefersSoftTopEdge()` asks for the soft fade on the TOP edge and nothing
/// else. The screens that call it are pinned in their own packages; this pins
/// what the call does and, as much, what it leaves alone.
@MainActor
struct SoftTopEdgeTests {
    @Test func theTopEdgeAsksForTheSoftFade() {
        let scrollView = UIScrollView()
        scrollView.prefersSoftTopEdge()
        #expect(scrollView.topEdgeEffect.style == .soft)
    }

    /// The default really is `.automatic`, so the assertion above says
    /// something: a style that started soft would pass it with the call gone.
    @Test func theDefaultIsAutomaticRatherThanSoft() {
        let scrollView = UIScrollView()
        #expect(scrollView.topEdgeEffect.style == .automatic)
        #expect(scrollView.topEdgeEffect.style != .soft)
    }

    /// The bottom edge — above the tab bar, a toolbar, a composer — is not what
    /// the call is about, and keeps the system's choice.
    @Test func theBottomEdgeKeepsTheSystemsChoice() {
        let scrollView = UIScrollView()
        scrollView.prefersSoftTopEdge()
        #expect(scrollView.bottomEdgeEffect.style == .automatic)
    }

    /// ⚠️ It never un-hides. A scroll view whose effects are hidden on purpose
    /// should not be calling it at all, but if one does, it stays hidden.
    @Test func aHiddenEdgeStaysHidden() {
        let scrollView = UIScrollView()
        scrollView.topEdgeEffect.isHidden = true
        scrollView.prefersSoftTopEdge()
        #expect(scrollView.topEdgeEffect.isHidden)
    }

    /// The lists call it on their own instance, so it must reach subclasses —
    /// a table and a collection view are the two it is called on most.
    @Test func itReachesTablesAndCollectionViews() {
        let table = UITableView(frame: .zero, style: .plain)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        table.prefersSoftTopEdge()
        collection.prefersSoftTopEdge()
        #expect(table.topEdgeEffect.style == .soft)
        #expect(collection.topEdgeEffect.style == .soft)
    }
}

/// The pager asks for it too, because its own scroll view spans the header and
/// draws its own effect: with only the pages soft, iOS 27 still cut the header
/// off at a hard line with a hairline (measured on the Messages inbox).
@MainActor
struct HorizontalPagerSoftTopEdgeTests {
    @Test func aPagerFadesUnderItsHeaderByDefault() {
        let pager = HorizontalPagerView(pages: [UIView(), UIView()])
        #expect(pager.pagingScrollView.topEdgeEffect.style == .soft)
    }

    /// ⚠️ The one host that opts out — the media picker, whose album has never
    /// had a fade under its bar on either system — must really get
    /// `.automatic`, or the opt-out is a parameter that does nothing.
    @Test func aPagerThatOptsOutKeepsTheSystemsChoice() {
        let pager = HorizontalPagerView(pages: [UIView(), UIView()], prefersSoftTopEdge: false)
        #expect(pager.pagingScrollView.topEdgeEffect.style == .automatic)
    }
}
