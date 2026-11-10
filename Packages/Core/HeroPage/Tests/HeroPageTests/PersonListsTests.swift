import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import HeroPage

/// The lists behind a hero header's counters (#2237): read page by page, a
/// short list reported, an empty tab saying so, the screen opened on the
/// counter's tab.
@MainActor
struct PersonListsTests {
    /// A source over `count` made-up people per tab, `pageSize` a page.
    private final class Source: PersonListsSource {
        var counts: [String: Int]
        let pageSize: Int
        /// A total the pages claim beyond what they hold — a bug to report.
        var claimedExtra = 0
        private(set) var asked: [(tab: String, token: String?)] = []
        private(set) var opened: [String] = []

        init(counts: [String: Int], pageSize: Int = 30) {
            self.counts = counts
            self.pageSize = pageSize
        }

        func page(of tab: String, after token: String?) async throws -> PersonListPage {
            asked.append((tab, token))
            let total = counts[tab] ?? 0
            let start = Int(token ?? "") ?? 0
            let end = min(start + pageSize, total)
            let rows = (start..<end).map { PersonListRow(id: "\(tab)-\($0)", name: "Person \($0)", detail: "", monogram: "P") }
            return PersonListPage(rows: rows, nextPageToken: end < total ? String(end) : nil, total: total + claimedExtra)
        }

        func open(_ row: PersonListRow, in tab: String, from screen: PersonListsViewController) { opened.append(row.id) }
        func perform(_ action: PersonListRowAction, on row: PersonListRow, in tab: String, from screen: PersonListsViewController) {}
        func answer(_ row: PersonListRow, approve: Bool, in tab: String, from screen: PersonListsViewController) {}
        func performLeadingAction(in tab: String, from screen: PersonListsViewController) {}
    }

    /// A budget of looks, not of time, and a wide one: the suite runs in
    /// parallel, and a starved runner ran out of 300 (the empty tab's read
    /// had not landed).
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func rows(_ feed: PersonListFeed) -> [PersonListRow] {
        if case .content(let rows, _) = feed.phase { return rows }
        return []
    }

    @Test func aListReadsItsFirstPageThenTheNextAsItNearsItsEnd() async {
        let source = Source(counts: ["subscribers": 64])
        let feed = PersonListFeed(tab: "subscribers", source: source)
        feed.start()
        await settle { feed.rows.count == 30 }
        #expect(feed.rows.count == 30, "one page, not the audience")
        #expect(feed.pagesRequested == 1)
        #expect(!feed.isComplete)
        feed.start()
        #expect(feed.pagesRequested == 1, "a second start reads nothing")

        feed.loadMoreIfNeeded()
        await settle { feed.rows.count == 60 }
        #expect(feed.pagesRequested == 2)
        feed.loadMoreIfNeeded()
        await settle { feed.isComplete }
        #expect(rows(feed).count == 64)
        #expect(feed.total == 64)
        #expect(source.asked.map(\.token) == [nil, "30", "60"])
        feed.loadMoreIfNeeded()
        #expect(feed.pagesRequested == 3, "a complete list asks no more")
    }

    @Test func anEmptyTabIsEmptyNotAHeaderOverNothing() async {
        // The feed holds its source weakly: kept here, or it is gone before
        // the first read and the tab never leaves `.loading`.
        let source = Source(counts: [:])
        let feed = PersonListFeed(tab: "requests", source: source)
        feed.start()
        await settle { feed.phase != .loading }
        #expect(feed.phase == .empty)
        withExtendedLifetime(source) {}
    }

    @Test func aListShorterThanItsTotalIsReported() async {
        let source = Source(counts: ["members": 5])
        source.claimedExtra = 3
        let feed = PersonListFeed(tab: "members", source: source)
        var reported: (Int, Int)?
        feed.onShortList = { reported = ($0, $1) }
        feed.start()
        await settle { feed.isComplete }
        #expect(reported?.0 == 5 && reported?.1 == 8)
        #expect(rows(feed).count == 5, "drawn as what came, never padded")
    }

    @Test func aReloadReadsFromTheFirstPage() async {
        let source = Source(counts: ["admins": 2])
        let feed = PersonListFeed(tab: "admins", source: source)
        feed.start()
        await settle { feed.isComplete }
        source.counts["admins"] = 1
        feed.reload()
        await settle { feed.rows.count == 1 }
        #expect(feed.rows.map(\.id) == ["admins-0"])
    }

    @Test func theScreenOpensOnTheCountersTabAndReadsOnlyIt() async throws {
        let source = Source(counts: ["members": 3, "admins": 1, "requests": 0])
        let tabs = ["members", "admins", "requests"].map {
            PersonListTab(id: $0, title: $0, empty: .init(symbol: "person.2", title: "No \($0)"))
        }
        let screen = PersonListsViewController(
            title: "Group", tabs: tabs, initialTab: "admins", source: source,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        #expect(screen.activeTab == "admins")
        #expect(screen.debugTabIDs == ["members", "admins", "requests"])
        let admins = try #require(screen.debugFeed("admins"))
        await settle { admins.isComplete }
        #expect(admins.rows.count == 1)
        #expect(screen.debugEmptyTitle("requests") == "No requests")
        #expect(screen.leaving == .nativeBack)
    }

    /// A conversation's header (#2237): a channel's megaphone after its
    /// name, and "by @owner" opening the owner.
    @Test func theHeaderWearsATitleSymbolAndATappableSubtitle() {
        let header = HeroHeaderView(
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), counters: ["Subscribers", "Admins", "Requests"]
        )
        header.configure(with: HeroHeaderContent(
            title: "Daily light", subtitle: "Public channel · by @ava", titleSymbol: "megaphone.fill",
            counterValues: ["12.4K", "2", nil]
        ))
        #expect(header.debugTitleSymbol == "megaphone.fill")
        var tapped = false
        header.onSubtitleTapped = { tapped = true }
        header.debugTapSubtitle()
        #expect(tapped)
        header.configure(with: HeroHeaderContent(title: "Weekend hike", subtitle: "Private group", counterValues: ["5", "2"]))
        #expect(header.debugTitleSymbol == nil)
    }
}
