import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import HeroPage

/// The hero page's container (#1655), on a page kind made only for this
/// test: a place-like header — two counters, no banner, a custom disc — over
/// one tab. It lays out, docks, refreshes, and shows no selector.
@MainActor
struct HeroPageViewControllerTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    fileprivate enum FixtureTab: Equatable { case popular }

    /// The test-only page kind: what a page kind hands the container, and the
    /// contract's calls it receives.
    private final class FixtureHeroPage: HeroPageViewController<FixtureTab> {
        let page: StubPage
        private(set) var refreshes = 0
        private(set) var travels: [CGFloat] = []

        init(fetcher: ImageFetching) {
            let header = HeroHeaderView(
                imagePipeline: ImagePipeline(fetcher: fetcher), counters: ["Ranking", "Likes"], avatar: .custom(UIView())
            )
            header.setActions([
                .capsule(AppButton(aspect: .pill(.quiet), size: .header, content: .title("Add Pin to Map"))),
                .bubble(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("qrcode")))
            ])
            header.configure(with: HeroHeaderContent(title: "Paris", subtitle: "France", counterValues: ["#3", "29.4K"]))
            let page = StubPage()
            self.page = page
            super.init(
                header: header, pager: HeroPagePager(tabs: [FixtureTab.popular], pages: [page]),
                selectorBar: PagedTabBar(titles: ["Popular"], style: .navigationTitle)
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func heroPageRefresh() { refreshes += 1 }
        override func heroPageHeaderDidMove(travelled: CGFloat) { travels.append(travelled) }
    }

    /// Hosts the page in a visible window for the length of `body`, then takes
    /// the window down (`visible-window-suite-release-crash`).
    private func hosting(_ body: (FixtureHeroPage) throws -> Void) rethrows {
        let screen = FixtureHeroPage(fetcher: SilentFetcher())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(screen)
    }

    /// The header floats over the page, from under the bar, and the page is
    /// inset by exactly the header's height; with no picture there is no
    /// banner.
    @Test func itLaysTheHeaderOverThePage() {
        hosting { screen in
            let height = screen.headerHeight
            #expect(height > 0)
            #expect(abs(height - screen.measuredHeaderHeight) < 0.5, "the cached height disagrees")
            #expect(screen.page.hostedInsets?.top == height, "the page is not inset by the header")
            #expect(screen.heroHeader.bannerFormat == .none)
            #expect(screen.heroHeader.debugBannerIsHidden)
            #expect(screen.heroHeader.chromeTopInset == screen.view.safeAreaInsets.top)
            #expect(screen.heroHeader.debugStatFrames.compactMap { $0 }.count == 2)
            // The header's views: in front of the page, under the pull.
            let subviews = screen.view.subviews
            let pager = subviews.firstIndex(of: screen.heroPager)
            let host = subviews.firstIndex(of: screen.headerHost)
            #expect(pager != nil && host != nil && pager! < host!, "the header is not over the page")
        }
    }

    /// The page climbing past the dock line takes the header to it and no
    /// further, fades the identity out, and tells the page kind each move;
    /// a pull carries the header down with the content.
    @Test func itDocksUnderTheBar() throws {
        try hosting { screen in
            let dock = screen.headerTravel
            #expect(dock > 0)
            let onPage = try #require(screen.page.onVerticalScroll)
            onPage(dock + 300)
            screen.view.layoutIfNeeded()
            let docked = screen.headerHost.frame.minY
            #expect(abs(docked + dock) < 0.5, "the header did not stop at the dock line: \(docked)")
            #expect(screen.heroHeader.alpha < 0.01, "the identity did not fade at the dock")
            #expect(!screen.headerHost.isUserInteractionEnabled, "a faded header still takes touches")
            #expect(screen.isActionRowUnderBar(travelled: dock + 300))

            onPage(-40)
            screen.view.layoutIfNeeded()
            #expect(abs(screen.headerHost.frame.minY - 40) < 0.5, "a pull did not carry the header down")
            #expect(screen.heroHeader.alpha == 1)
            #expect(!screen.isActionRowUnderBar(travelled: -40))
            #expect(screen.travels == [dock + 300, -40])
        }
    }

    /// A pull released past the threshold turns the spinner and asks the page
    /// kind; one released short does neither.
    @Test func aReleasedPullRefreshes() {
        hosting { screen in
            screen.heroPager.onPullReleased?(HeroPullToRefreshView.threshold / 2)
            #expect(screen.refreshes == 0)
            #expect(!screen.pullIndicator.debugIsRefreshing)
            screen.heroPager.onPullReleased?(HeroPullToRefreshView.threshold + 40)
            #expect(screen.refreshes == 1)
            #expect(screen.pullIndicator.debugIsRefreshing)
            screen.pullIndicator.endRefreshing()
        }
    }

    /// One tab is no selector: nothing in the toolbar, nothing in an
    /// accessory, the status block hidden.
    @Test func oneTabShowsNoSelector() {
        hosting { screen in
            #expect(!screen.selector.isPlaced)
            #expect(screen.selector.item == nil && screen.selector.accessory == nil)
            #expect(screen.selectorBar.window == nil)
            #expect(screen.statusView.isHidden)
        }
    }
}
