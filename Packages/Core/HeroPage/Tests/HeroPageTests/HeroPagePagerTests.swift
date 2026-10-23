import DesignSystem
import FeedInterface
import PostGrid
import Testing
import UIKit
@testable import HeroPage

/// The hero page's pager (#1653): what makes a page kind's pages one surface,
/// keyed by its own tabs — tested here on stand-in pages, so the profile's and
/// a place's are not needed to pin it.
@MainActor
@Suite(.serialized)
struct HeroPagePagerTests {
    private enum Tab: Equatable { case posts, saved, liked }

    private func makePager(_ tabs: [Tab] = [.posts, .saved, .liked]) -> (HeroPagePager<Tab>, [StubPage]) {
        let pages = tabs.map { _ in StubPage() }
        let pager = HeroPagePager(tabs: tabs, pages: pages)
        pager.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        pager.layoutIfNeeded()
        return (pager, pages)
    }

    /// Hiding a tab keeps the page being read; hiding THAT one falls back to
    /// the first.
    @Test func hidingTabsKeepsThePageBeingRead() {
        let (pager, _) = makePager()
        pager.setActivePage(.saved, animated: false)
        pager.setVisibleTabs([.posts, .saved])
        #expect(pager.pageOrder == [.posts, .saved])
        #expect(pager.debugActiveTab == .saved)
        pager.setVisibleTabs([.posts, .liked])
        #expect(pager.pageOrder == [.posts, .liked])
        #expect(pager.debugActiveTab == .posts, "the page going away was the one being read")
    }

    /// Below the dock line every page shares the screen's offset — the
    /// header is one object; above it each keeps its own place, never above
    /// its first row.
    @Test func aTabSwitchAlignsTheArrivingPage() {
        let (pager, pages) = makePager()
        pager.setSharedTravel(dockLine: 100, contentFloor: 160)

        pages[0].setVerticalOffset(50, animated: false)
        pager.setActivePage(.saved, animated: false)
        #expect(pages[1].verticalOffset == 50, "below the dock line the arriving page did not follow")

        pages[1].setVerticalOffset(300, animated: false)
        pages[2].setVerticalOffset(400, animated: false)
        pager.setActivePage(.liked, animated: false)
        #expect(pages[2].verticalOffset == 400, "above the dock line a page lost its own place")

        pages[0].setVerticalOffset(20, animated: false)
        pager.setActivePage(.posts, animated: false)
        #expect(pages[0].verticalOffset == 160, "a docked arrival sat above its first row")
    }

    /// Only the page being read reports its scroll and its pull.
    @Test func onlyTheActivePageDrivesTheHeader() {
        let (pager, pages) = makePager()
        var told: [CGFloat] = []
        pager.onVerticalScroll = { told.append($0) }
        pages[1].onVerticalScroll?(80)
        #expect(told.isEmpty, "a page off screen drove the header")
        pages[0].onVerticalScroll?(40)
        #expect(told == [40])
        #expect(pager.isActive(pages[0]) && !pager.isActive(pages[1]))
    }

    /// One tab: nothing to scrub.
    @Test func aSingleTabCannotBeScrubbed() {
        let (pager, _) = makePager([.posts])
        pager.scrub(to: 0.7)
        #expect(pager.debugContentOffsetX == 0)
        #expect(!pager.debugIsScrubbing)
    }

    /// Every page is hosted under the floating header from birth.
    @Test func everyPageIsHandedToTheHost() {
        let (_, pages) = makePager()
        #expect(pages.allSatisfy { $0.handedPull && $0.hostedInsets == .zero })
    }
}

/// The hero page's selector (#1653): placed once in its home, removed when
/// one tab is left, and in step with the pager both ways.
@MainActor
@Suite(.serialized)
struct HeroPageSelectorTests {
    private enum Tab: Equatable { case posts, saved }

    @Test func aToolbarPlacementHandsTheScreenItsItemsOnceAndTakesThemBack() {
        let screen = UIViewController()
        let selector = HeroPageSelector(bar: PagedTabBar(titles: ["Posts", "Saved"], style: .navigationTitle), placement: .toolbar)
        selector.place(on: screen)
        let item = selector.item
        #expect(item != nil && screen.toolbarItems?.first === item)
        #expect(selector.accessory == nil)
        selector.place(on: screen)
        #expect(selector.item === item, "placed twice")
        selector.remove(from: screen)
        #expect(!selector.isPlaced && (screen.toolbarItems ?? []).isEmpty)
    }

    @Test func anAccessoryPlacementBuildsTheBand() {
        let screen = UIViewController()
        let selector = HeroPageSelector(bar: PagedTabBar(titles: ["Posts", "Saved"], style: .navigationTitle), placement: .accessory)
        selector.place(on: screen)
        #expect(selector.accessory != nil && selector.item == nil)
        #expect(screen.toolbarItems == nil, "an accessory placement wrote the toolbar")
    }

    /// The lens follows the pages, a tap selects through `onSelect`, a
    /// selection already shown says nothing.
    @Test func theStripAndThePagerStayInStep() {
        let pager = HeroPagePager<Tab>(tabs: [.posts, .saved], pages: [StubPage(), StubPage()])
        pager.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        pager.layoutIfNeeded()
        let bar = PagedTabBar(titles: ["Posts", "Saved"], style: .navigationTitle)
        let selector = HeroPageSelector(bar: bar, placement: .toolbar)
        var selected: [Int] = []
        selector.bind(to: pager) { selected.append($0) }

        selector.select(1)
        #expect(selected == [1])
        selector.select(1)
        #expect(selected == [1], "re-selecting the segment on show echoed")
        #expect(pager.onProgress != nil, "the lens does not follow the pages")
    }
}

/// A page with an offset and nothing else.
@MainActor
final class StubPage: UIView, PostGridPage {
    private(set) var verticalOffset: CGFloat = 0
    private(set) var handedPull = false
    private(set) var hostedInsets: UIEdgeInsets?
    let scrollView = UIScrollView()

    func show(_ state: PostGridPageState) {}
    func setCorpusComplete(_ complete: Bool) {}
    var showsTileInfo = false
    var staking: PostCardStaking?
    var onPostTapped: ((GalleryPost, [GalleryPost], Bool) -> Void)?
    var onNearEnd: (() -> Void)?
    var onViewAllTapped: (() -> Void)?
    var onAuthorTapped: ((GalleryPost) -> Void)?
    var postMenuActions: ((PostGridAuthorMenuContext) -> [PostCardMenuAction])?
    var onRefresh: (() -> Void)?
    func refreshAuthorMenus() {}
    var onVerticalScroll: ((CGFloat) -> Void)?
    var onPullReleased: ((CGFloat) -> Void)?
    func setVerticalOffset(_ offset: CGFloat, animated: Bool) { verticalOffset = offset }
    func setHostedInsets(top: CGFloat, bottom: CGFloat) {
        hostedInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    }
    func setMinimumScrollTravel(_ travel: CGFloat) {}
    func setChromeOcclusion(_ occlusion: UIEdgeInsets?) {}
    var snapDetents: [CGFloat] = []
    var catchDetents: [CGFloat] = []
    func handPullToHost() { handedPull = true }
    func setPinLineInset(_ inset: CGFloat?) {}
    var onPinnedSectionChanged: ((PostGridPinnedSection?) -> Void)?
    var pinnedSection: PostGridPinnedSection?
    func scrollToSection(_ index: Int) {}
    func setPageActive(_ active: Bool) {}
    func applyPendingReveal() {}
    func heroOrigin(
        opening tapped: GalleryPost, stream: [GalleryPost], in host: UIView,
        textReveal: TextRevealOrigin?, opensComments: Bool,
        willStageDismissal: @escaping () -> Void, pinsBeforeClose: Bool,
        continuation: SnapFeedContinuation?
    ) -> SnapFeedHeroOrigin {
        fatalError("not opened in these tests")
    }
    func closeWindow(
        for post: GalleryPost, alignsPageToSource: Bool,
        willStageDismissal: @escaping () -> Void, dismissalDidEnd: @escaping (Bool) -> Void
    ) -> TextRevealOrigin? { nil }
    func openHoldingStill(from host: UIViewController, _ open: () -> Void) { open() }
    func endPlaybackHandoff() {}
}
