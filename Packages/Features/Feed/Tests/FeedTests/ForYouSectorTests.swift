import DesignSystem
import Testing
import UIKit
@testable import Feed

/// (#1703, #1705): the For You tab as a Feed | Shots sector — it opens on
/// Shots, wears the bar of the page in front (the selector inboard of the
/// page's own leading item), and hands each page its bar back when it leaves.
@MainActor
struct ForYouSectorTests {
    /// A page that composes its bar the way the real ones do: through
    /// `navigationItem`, which answers the sector's item while in front.
    final class Page: UIViewController, ForYouSectorPage {
        let mark: UIBarButtonItem
        var ownsDrag = false
        private(set) var activity: [Bool] = []
        private(set) var handedInsets: UIEdgeInsets?
        var sectorNavigationItem: UINavigationItem?
        var sectorSelectorItem: UIBarButtonItem? { didSet { composeBar() } }

        init(mark: String) {
            self.mark = UIBarButtonItem(title: mark)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var navigationItem: UINavigationItem { sectorNavigationItem ?? super.navigationItem }
        var ownNavigationItem: UINavigationItem { super.navigationItem }

        func composeBar() {
            navigationItem.leftBarButtonItems = [mark] + [sectorSelectorItem].compactMap { $0 }
        }

        func sectorPageDidChangeActivity(_ isActive: Bool) { activity.append(isActive) }
        func sectorSafeAreaDidChange(_ insets: UIEdgeInsets) { handedInsets = insets }
        func sectorPageOwnsHorizontalDrag(velocity: CGPoint) -> Bool { ownsDrag }
    }

    private func sector() -> (ForYouSectorViewController, feed: Page, shots: Page) {
        let home = Page(mark: "home")
        let feed = Page(mark: "feed")
        let sector = ForYouSectorViewController(feed: home, shots: feed)
        sector.loadViewIfNeeded()
        sector.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        sector.view.layoutIfNeeded()
        return (sector, home, feed)
    }

    @Test func itOpensOnFeedWearingItsBarAndTheSelector() {
        let (sector, _, feed) = sector()
        #expect(sector.activeIndex == ForYouSectorViewController.shotsIndex)
        let items = sector.navigationItem.leftBarButtonItems ?? []
        #expect(items.first === feed.mark, "the bar is not the feed's")
        #expect(items.contains { $0.identifier == ForYouSectorViewController.selectorItemID }, "no selector")
    }

    /// Paging to Feed swaps the bar, takes Shots' home with it, and tells
    /// both pages; a write by the page in front lands in the bar on screen.
    /// Shots, then Feed, as the selector reads (#1705).
    @Test func theSelectorReadsFeedThenShots() {
        let (sector, _, _) = sector()
        #expect(ForYouSectorViewController.titles == ["Feed", "Shots"])
        let selector = sector.navigationItem.leftBarButtonItems?
            .first { $0.identifier == ForYouSectorViewController.selectorItemID }?.customView
        #expect(selector is PagedTabBar)
    }

    /// DEBUG: the For You QA hooks open the sector on Feed, where the list
    /// they drive lives; a plain launch opens on Shots.
    @Test func theQAHooksOpenOnFeed() {
        #expect(ForYouSectorViewController.startIndex(arguments: ["app"]) == ForYouSectorViewController.shotsIndex)
        #expect(ForYouSectorViewController.startIndex(arguments: ["app", "-foryou-open"]) == ForYouSectorViewController.feedIndex)
        #expect(ForYouSectorViewController.startIndex(arguments: ["app", "-hero-audit"]) == ForYouSectorViewController.feedIndex)
    }

    @Test func pagingSwapsTheBarAndHandsTheOldOneBack() {
        let (sector, home, feed) = sector()
        sector.showPage(ForYouSectorViewController.feedIndex, animated: false)

        #expect(sector.activeIndex == ForYouSectorViewController.feedIndex)
        #expect(sector.navigationItem.leftBarButtonItems?.first === home.mark)
        #expect(feed.ownNavigationItem.leftBarButtonItems?.first === feed.mark, "the feed's bar was lost")
        #expect(home.activity == [true])
        #expect(feed.activity == [false])

        let written = UIBarButtonItem(title: "new")
        home.navigationItem.rightBarButtonItems = [written]
        #expect(sector.navigationItem.rightBarButtonItems?.first === written, "the page in front wrote off screen")
    }

    /// The sector's insets reach the pages (UIKit gives Feed none in here).
    @Test func thePagesAreHandedTheSectorsInsets() {
        let (_, home, feed) = sector()
        #expect(home.handedInsets != nil)
        #expect(feed.handedInsets != nil)
    }
}
