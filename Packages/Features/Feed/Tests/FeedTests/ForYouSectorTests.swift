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

    // MARK: - The change of page (#1707)

    /// 100% blur at 0% of the screen, none from half on, linear between.
    @Test func theBlurFollowsTheShareOfTheScreen() {
        #expect(ForYouSectorViewController.blurAmount(occupancy: 0) == 1)
        #expect(abs(ForYouSectorViewController.blurAmount(occupancy: 0.25) - 0.5) < 0.0001)
        #expect(ForYouSectorViewController.blurAmount(occupancy: 0.5) == 0)
        #expect(ForYouSectorViewController.blurAmount(occupancy: 0.8) == 0)
    }

    /// Mid-drag, the page over half the screen is the page in front — its
    /// bar, its appearance (Shots plays) — and each page blurs by its share;
    /// at rest, no blur is left.
    @Test func thePageOverHalfIsInFrontAndTheOtherBlurs() {
        let (sector, home, feed) = sector()
        sector.debugApplyOccupancy(shotsShare: 0.4)
        #expect(sector.activeIndex == ForYouSectorViewController.feedIndex, "Shots under half kept the front")
        #expect(home.activity == [true])
        #expect(feed.activity == [false])
        let amounts = sector.debugBlurAmounts
        #expect(amounts[ForYouSectorViewController.feedIndex] == 0, "the page over half is blurred")
        #expect(abs(amounts[ForYouSectorViewController.shotsIndex] - 0.2) < 0.0001)

        sector.debugApplyOccupancy(shotsShare: 0.6)
        #expect(sector.activeIndex == ForYouSectorViewController.shotsIndex, "back over half, Shots did not come back")

        sector.debugApplyOccupancy(shotsShare: 1)
        #expect(sector.debugBlurAmounts == [0, 0], "a blur outlived the drag")
    }

    /// The sector's insets reach the pages (UIKit gives Feed none in here).
    @Test func thePagesAreHandedTheSectorsInsets() {
        let (_, home, feed) = sector()
        #expect(home.handedInsets != nil)
        #expect(feed.handedInsets != nil)
    }
}
