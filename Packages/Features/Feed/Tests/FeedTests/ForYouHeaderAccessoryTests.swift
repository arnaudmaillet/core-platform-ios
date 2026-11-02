import CoreModels
import CoreNavigation
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **The header's injected trailing item — the wallet badge, from out here.**
///
/// The balance already stands in the Explore header and on the post screen. It
/// is the same number in all three places, so the screens do not each learn
/// what a wallet is: the shell builds ONE item and hands it over, and this
/// screen only promises to keep it in its trailing run.
///
/// That promise is the thing worth testing, because the run is rebuilt: the
/// screen writes its own items at load, and an item installed from outside has
/// to survive that write and every later one.
@MainActor
struct ForYouHeaderAccessoryTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func screen() -> ForYouViewController {
        ForYouViewController(
            viewModel: ForYouViewModel(
                repository: StubHeaderProvider()
            ),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeSnapFeed: { _, _ in UIViewController() },
            prewarm: { _ in }
        )
    }

    private func accessory() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: UIView())
        item.accessibilityLabel = "Balance"
        return item
    }

    /// For You's re-tap (#1309), on the app's REAL stack (#2013): its root
    /// is the Feed | Shots sector, not this screen, and the sector forwards
    /// the re-tap to Feed when Feed is in front. The old test built a stack
    /// with this screen as its root, a shape the app no longer has.
    @Test func forYouAnswersATabReTapThroughTheSector() {
        let screen = screen()
        let sector = ForYouSectorViewController(feed: screen, shots: SectorStubPage())
        sector.loadViewIfNeeded()
        sector.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        sector.view.layoutIfNeeded()
        let stack = UINavigationController(rootViewController: sector)
        let target = TabReselect.target(tappedSelectedTab: true, stack: stack)
        #expect(target === sector, "the shell's re-tap does not reach the sector")

        sector.showPage(ForYouSectorViewController.feedIndex, animated: false)
        screen.page.setVerticalOffset(600, animated: false)
        target?.scrollToTopForTabReselect()
        // Animated: give the scroll a few turns of the run loop.
        for _ in 0..<200 where screen.page.verticalOffset >= 600 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(screen.page.verticalOffset < 600, "Feed did not head for its top")
    }

    /// On Shots the re-tap changes nothing; Feed behind it stays where it is.
    @Test func onShotsTheReTapDoesNothing() {
        let screen = screen()
        let sector = ForYouSectorViewController(feed: screen, shots: SectorStubPage())
        sector.loadViewIfNeeded()
        sector.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        sector.view.layoutIfNeeded()
        sector.showPage(ForYouSectorViewController.shotsIndex, animated: false)
        screen.page.setVerticalOffset(600, animated: false)
        let before = screen.page.verticalOffset
        sector.scrollToTopForTabReselect()
        #expect(screen.page.verticalOffset == before, "a re-tap on Shots scrolled the Feed")
        #expect(sector.activeIndex == ForYouSectorViewController.shotsIndex, "a re-tap on Shots changed the page")
    }

    /// The rule: only a settled Feed in front, the drawer closed.
    @Test func onlyASettledFeedInFrontScrolls() {
        typealias Sector = ForYouSectorViewController
        #expect(Sector.reselectScrollsFeed(activeIndex: Sector.feedIndex, pagerMoving: false, drawerOpen: false))
        #expect(!Sector.reselectScrollsFeed(activeIndex: Sector.shotsIndex, pagerMoving: false, drawerOpen: false))
        #expect(!Sector.reselectScrollsFeed(activeIndex: Sector.feedIndex, pagerMoving: true, drawerOpen: false))
        #expect(!Sector.reselectScrollsFeed(activeIndex: Sector.feedIndex, pagerMoving: false, drawerOpen: true))
    }

    /// With nothing injected the header is what it always was: one trailing
    /// item, search.
    @Test func theHeaderKeepsItsOwnItemWhenNothingIsInjected() {
        let screen = screen()
        screen.loadViewIfNeeded()

        #expect(screen.navigationItem.rightBarButtonItems?.count == 1)
    }

    /// ⚠️ THE BADGE STANDS INBOARD OF THE SCREEN'S OWN ITEM.
    ///
    /// `rightBarButtonItems[0]` is the one nearest the screen edge, so search
    /// keeps the corner and the balance sits to its left — the arrangement the
    /// Explore header already wears ([coins] [search]).
    @Test func theInjectedBadgeStandsInboardOfSearch() throws {
        let screen = screen()
        screen.loadViewIfNeeded()
        let badge = accessory()

        screen.setTrailingAccessoryItem(badge)

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.count == 2)
        #expect(items.last === badge, "the balance took the corner from search")
    }

    /// ⚠️ AND IT SURVIVES THE SCREEN'S OWN WRITE.
    ///
    /// The item can only be handed over once the screen exists, and the screen
    /// writes its trailing run at `viewDidLoad` — so an injection that happened
    /// first must not be erased by it. Ordered the awkward way round on
    /// purpose: injected BEFORE the view loads.
    @Test func anItemInjectedBeforeTheViewLoadsSurvives() throws {
        let screen = screen()
        let badge = accessory()

        screen.setTrailingAccessoryItem(badge)
        screen.loadViewIfNeeded()

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.contains { $0 === badge }, "the header's own write erased the badge")
    }

    /// Replacing it swaps the item rather than adding a second one — the badge
    /// hands over a FRESH `UIBarButtonItem` whenever its count changes width,
    /// because a bar measures a custom view once, at install.
    @Test func replacingTheItemLeavesOneOfIt() throws {
        let screen = screen()
        screen.loadViewIfNeeded()

        screen.setTrailingAccessoryItem(accessory())
        let second = accessory()
        screen.setTrailingAccessoryItem(second)

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.count == 2)
        #expect(items.last === second)
    }

    /// And clearing it puts the header back exactly as it was.
    @Test func clearingItRestoresTheHeader() throws {
        let screen = screen()
        screen.loadViewIfNeeded()

        screen.setTrailingAccessoryItem(accessory())
        screen.setTrailingAccessoryItem(nil)

        #expect(screen.navigationItem.rightBarButtonItems?.count == 1)
    }

    // MARK: - The leading item (the shell's bell)

    /// ⚠️ THE BELL LEADS ALONE (#1423): the content-context item that stood
    /// inboard of it is gone, so the header reads `[bell] … [coins][search]`.
    @Test func theInjectedBellLeadsAlone() throws {
        let screen = screen()
        screen.loadViewIfNeeded()
        let bell = accessory()

        screen.setLeadingAccessoryItem(bell)

        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.count == 1, "something stands beside the bell: \(items.map { $0.accessibilityLabel ?? "?" })")
        #expect(items.first === bell)
    }

    /// Injected before the view loads — the order the shell actually uses —
    /// it survives the screen's own write of the leading group at load.
    @Test func aBellInjectedBeforeTheViewLoadsSurvives() throws {
        let screen = screen()
        let bell = accessory()

        screen.setLeadingAccessoryItem(bell)
        screen.loadViewIfNeeded()

        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.first === bell, "the header's own write erased the bell")
    }

    /// Clearing it leaves the leading group empty.
    @Test func clearingTheBellLeavesTheLeadingGroupEmpty() {
        let screen = screen()
        screen.loadViewIfNeeded()

        screen.setLeadingAccessoryItem(accessory())
        screen.setLeadingAccessoryItem(nil)

        #expect(screen.navigationItem.leftBarButtonItems?.isEmpty ?? true)
    }
}

private final class StubHeaderProvider: ForYouProviding, @unchecked Sendable {
    func firstPage() async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
    func page(after token: String) async throws -> ForYouPage {
        ForYouPage(posts: [], nextPageToken: nil)
    }
}

/// A Shots page that does nothing: the re-tap tests are about the sector.
@MainActor
private final class SectorStubPage: UIViewController, ForYouSectorPage {
    var sectorNavigationItem: UINavigationItem?
    var sectorSelectorItem: UIBarButtonItem?
    var ownNavigationItem: UINavigationItem { super.navigationItem }
    func sectorPageDidChangeActivity(_ isActive: Bool) {}
    func sectorSafeAreaDidChange(_ insets: UIEdgeInsets) {}
}
