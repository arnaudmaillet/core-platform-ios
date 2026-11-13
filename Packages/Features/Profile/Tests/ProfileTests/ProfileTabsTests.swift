import CoreModels
import DesignSystem
import CoreStorage
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile
@testable import ProfileSettings

/// Which tabs a profile shows, and where the two new ones get their contents.
///
/// Saved and Liked are the viewer's own, in the strict sense that nothing on
/// the wire could hand either of them to anybody else: there is no save
/// contract at all, and reactions can be written and counted but never listed.
/// So the gating is not a policy choice to be revisited — it is the only shape
/// the data allows, and these pin it.
@MainActor
struct ProfileTabsTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    // MARK: - Who sees what

    /// ⚠️ THE PUBLIC PAGES, THEN SAVED AND LIKED (#772): Reposts and Tagged
    /// left the bar's source menu for the selector, as on anyone else's
    /// profile; Saved and Liked stay yours alone (#631). Channels follows
    /// Posts (#2232), shown only with a channel.
    @Test func yourOwnProfileCarriesThePublicPagesThenSavedAndLiked() {
        #expect(ProfileTab.ownTabs == [.format(.activity), .channels, .reposts, .tagged, .saved, .history, .reactions])
        #expect(ProfileTab.ownTabs.map(\.title) == ["Posts", "Channels", "Reposts", "Tagged", "Saved", "History", "Liked"])
    }

    /// ⚠️ And nobody else's does. A saved pile has no owner but the device it
    /// is on; showing one on a profile reached by tapping a handle would be
    /// showing the viewer their own pile under someone else's name.
    @Test func someoneElsesProfileCarriesNeither() {
        #expect(ProfileTab.publicTabs.contains(.saved) == false)
        #expect(ProfileTab.publicTabs.contains(.reactions) == false)
    }

    /// ⚠️ THREE PAGES (#696): anyone else's profile is Posts · Reposts ·
    /// Tagged, each its own list, where it was one list and a top filter —
    /// and Channels after Posts when it owns one (#2232).
    @Test func someoneElsesProfileIsPostsRepostsTagged() {
        #expect(ProfileTab.publicTabs == [.format(.activity), .channels, .reposts, .tagged])
        #expect(ProfileTab.publicTabs.map(\.title) == ["Posts", "Channels", "Reposts", "Tagged"])
    }

    /// Posts comes first on both, so a profile opens on the list a viewer
    /// knows from every other one.
    @Test func postsComesFirstOnBoth() {
        #expect(ProfileTab.ownTabs.first == .format(.activity))
        #expect(ProfileTab.publicTabs.first == .format(.activity))
    }

    /// Reposts and Tagged load more as they scroll, like Posts; Saved and
    /// Liked arrive whole, and so do a profile's channels (#2232).
    @Test func thePublishedPagesPage() {
        #expect(ProfileTab.publicTabs.filter { $0 != .channels }.allSatisfy { $0.pages })
        #expect(!ProfileTab.channels.pages)
        #expect(!ProfileTab.saved.pages && !ProfileTab.reactions.pages)
        #expect(ProfileTab.reposts.format == nil && ProfileTab.tagged.format == nil)
    }

    /// Posts is For You's Discover list; Saved and Liked stay timelines; the
    /// media mosaic is the gallery "View all" pushes.
    @Test func eachPageTakesItsShape() {
        #expect(ProfileGalleryPagerView.style(for: .format(.activity)) == .discover)
        #expect(ProfileGalleryPagerView.style(for: .saved) == .list)
        #expect(ProfileGalleryPagerView.style(for: .reactions) == .list)
        #expect(ProfileGalleryPagerView.style(for: .format(.media)) == .grid)
        // Someone else's Reposts and Tagged are For You lists too (#696).
        #expect(ProfileGalleryPagerView.style(for: .reposts) == .discover)
        #expect(ProfileGalleryPagerView.style(for: .tagged) == .discover)
    }

    // MARK: - Which axis they are on

    /// ⚠️ Saved and Liked are CORPORA, not formats. The source filter — All /
    /// Posts / Reposts / Tagged — asks what this profile published, and there
    /// is no answer to any of it about a post somebody else wrote. Reporting no
    /// format is what keeps the tray and the stored preference away from them.
    @Test func theCorpusTabsHaveNoFormat() {
        #expect(ProfileTab.saved.format == nil)
        #expect(ProfileTab.reactions.format == nil)
    }

    @Test func theFormatTabsReportTheirFormat() {
        #expect(ProfileTab.format(.activity).format == .activity)
        #expect(ProfileTab.format(.media).format == .media)
        #expect(ProfileTab.format(.short).format == .short)
    }

    /// Every tab is titled, and titled distinctly — five segments sharing one
    /// capsule with a repeat among them would be unreadable.
    @Test func everyTabHasItsOwnTitle() {
        let titles = ProfileTab.ownTabs.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    // MARK: - The pager follows the tab list

    private func pager(_ tabs: [ProfileTab]) -> ProfileGalleryPagerView {
        let pager = ProfileGalleryPagerView(tabs: tabs, makePage: TestGridPages.pageMaker())
        pager.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        pager.layoutIfNeeded()
        return pager
    }

    /// ⚠️ One PAGE per tab, each with its own scroll position — the page
    /// count used to be a constant, and a selector with more segments than
    /// the pager has pages indexes past the end on the last tab.
    @Test func thePagerBuildsOnePageForEachTab() {
        #expect(pager(ProfileTab.ownTabs).debugVerticalOffsets.count == 7)
        #expect(pager(ProfileTab.publicTabs).debugVerticalOffsets.count == 4)
    }

    /// And the new pages join the same coordinator as the old: each keeps its
    /// own place, which is the property the whole architecture turns on.
    @Test func theNewPagesKeepTheirOwnScrollPositions() {
        let pager = pager(ProfileTab.ownTabs)
        pager.setMinimumScrollTravel(2_000)
        pager.setSharedTravel(dockLine: 300, contentFloor: 360)
        pager.debugSetOffset(900, forPage: 2)
        pager.debugSetOffset(400, forPage: 0)
        #expect(pager.debugAlignedOffset(forPage: 2) == 900)
    }

    /// A swipe onto the last tab reports THAT tab — an off-by-one here lands
    /// the selector on Saved while the pager shows Liked.
    ///
    /// Driven through the scroll view's own settle, which is the only way a
    /// swipe commits now that the capsule carries no gesture of its own.
    @Test func settlingOnTheLastTabReportsIt() {
        let pager = pager(ProfileTab.ownTabs)
        var settled: [ProfileTab] = []
        pager.onPageSettled = { settled.append($0) }
        let last = CGFloat(ProfileTab.ownTabs.count - 1)
        pager.debugScrollView.contentOffset = CGPoint(x: last * pager.bounds.width, y: 0)
        pager.debugScrollView.delegate?.scrollViewDidEndDecelerating?(pager.debugScrollView)
        #expect(settled == [.reactions])
    }
}

/// The saved pile itself.
///
/// Client-owned, because no service carries one. That makes this store the only
/// source of truth there is for the Saved tab, which is a good reason for its
/// ordering and its persistence to be asserted rather than assumed.
struct PostBookmarkStoreTests {
    private func store() -> PostBookmarkStore {
        let defaults = UserDefaults(suiteName: "bookmark-tests-\(UUID().uuidString)")!
        return PostBookmarkStore(defaults: defaults)
    }

    @Test func aFreshPileIsEmpty() {
        #expect(store().savedPostIDs.isEmpty)
    }

    @Test func savingAndUnsavingAreTheSameTap() {
        let store = store()
        #expect(store.toggle("post-1") == true)
        #expect(store.isSaved("post-1"))
        #expect(store.toggle("post-1") == false)
        #expect(store.isSaved("post-1") == false)
        #expect(store.savedPostIDs.isEmpty)
    }

    /// ⚠️ Newest first. A saved pile is read as a pile, not as a set: the thing
    /// you saved a minute ago is the thing you came back for, and appending
    /// would bury it under everything older.
    @Test func theMostRecentlySavedComesFirst() {
        let store = store()
        store.toggle("post-1")
        store.toggle("post-2")
        store.toggle("post-3")
        #expect(store.savedPostIDs == ["post-3", "post-2", "post-1"])
    }

    /// Re-saving something moves it back to the front rather than duplicating
    /// it — the pile is ordered, but it is still a set.
    @Test func savingSomethingTwiceDoesNotDuplicateIt() {
        let store = store()
        store.toggle("post-1")
        store.toggle("post-2")
        store.toggle("post-1")  // unsaves
        store.toggle("post-1")  // saves again
        #expect(store.savedPostIDs == ["post-1", "post-2"])
    }

    /// ⚠️ It outlives the object. This is the whole difference from the session
    /// `Set` it replaced: two surfaces read this list, and one of them is a
    /// screen the other has never met.
    @Test func thePileOutlivesTheStoreThatWroteIt() {
        let defaults = UserDefaults(suiteName: "bookmark-persist-\(UUID().uuidString)")!
        PostBookmarkStore(defaults: defaults).toggle("post-7")
        #expect(PostBookmarkStore(defaults: defaults).savedPostIDs == ["post-7"])
    }

    /// Changes announce themselves, so the Saved tab reloads rather than polls.
    @Test func aChangeIsAnnounced() {
        let store = store()
        var changes = 0
        store.onChange = { changes += 1 }
        store.toggle("post-1")
        store.toggle("post-1")
        #expect(changes == 2)
    }
}

/// What each tab says when it has nothing.
///
/// A blank grid reads as a screen that failed. The difference between that and
/// "there is genuinely nothing here" is the entire reason the shared empty
/// state exists — and on a five-tab profile it also has to say WHICH nothing,
/// because an empty Gallery and an empty Saved pile look identical and mean
/// completely different things.
@MainActor
struct ProfileEmptyStateTests {
    @Test func everyTabSaysWhichNothingItIs() {
        let states = ProfileTab.ownTabs.map(\.emptyState)
        #expect(Set(states.map(\.title)).count == states.count)
        #expect(Set(states.map(\.subtitle)).count == states.count)
        #expect(Set(states.map(\.symbol)).count == states.count)
    }

    @Test func everyTabCarriesAllThreeParts() {
        for state in ProfileTab.ownTabs.map(\.emptyState) {
            #expect(!state.symbol.isEmpty)
            #expect(!state.title.isEmpty)
            #expect(!state.subtitle.isEmpty)
        }
    }

    /// ⚠️ Every glyph resolves. A symbol name with a typo in it renders as
    /// nothing at all — the block loses its anchor and no test that only checks
    /// the string would notice.
    @Test func everyGlyphIsARealSymbol() {
        for state in ProfileTab.ownTabs.map(\.emptyState) {
            #expect(UIImage.symbol(named: state.symbol) != nil, "\(state.symbol) does not resolve")
        }
    }

    /// The copy itself, pinned — it was specified, so a change to it should be
    /// a decision rather than a drift.
    @Test func theCopyIsWhatWasAskedFor() {
        // Posts is every post since #631, and says so; the media gallery is
        // photos and videos.
        #expect(ProfileTab.format(.activity).emptyState.title == "No Posts Yet")
        #expect(ProfileTab.format(.activity).emptyState.subtitle == "Posts and reposts will appear here.")
        #expect(ProfileTab.format(.media).emptyState.title == "No Photos or Videos")
        #expect(ProfileTab.saved.emptyState.title == "No Saved Posts")
        #expect(ProfileTab.reactions.emptyState.title == "No Reactions Yet")

        #expect(ProfileTab.saved.emptyState.subtitle == "Posts you bookmark will appear here.")
        #expect(
            ProfileTab.reactions.emptyState.subtitle
                == "Posts you react to or like will show up here."
        )
    }
}

/// History (#1344): one post per row (#2170), and the viewer's own profile
/// only.
@MainActor
struct ProfileHistoryTabTests {
    @Test func historyIsOnePostPerRow() {
        #expect(ProfileGalleryPagerView.style(for: .history) == .rows)
        // Saved and Liked keep theirs (#2170).
        #expect(ProfileGalleryPagerView.style(for: .saved) == .list)
        #expect(ProfileGalleryPagerView.style(for: .reactions) == .list)
        #expect(ProfileTab.history.title == "History")
        #expect(!ProfileTab.history.pages)
    }

    @Test func historyIsTheOwnProfilesOnly() {
        let store = ProfileGalleryStore()
        store.history = .content([])
        if case .content = store.snapshot(isOwnProfile: false).history {
            Issue.record("someone else's profile showed the viewer's history")
        }
        if case .content = store.snapshot(isOwnProfile: true).history {} else {
            Issue.record("the own profile lost its history")
        }
    }
}

/// History's days (#1344, the owner 2026-10-17): the posts under the time
/// they were viewed, and the page titling them.
@MainActor
struct ProfileHistoryDaysTests {
    /// Saturday 17 October 2026, noon, in a fixed calendar (weeks from Sunday).
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }()
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!

    private func daysAgo(_ days: Int) -> Date {
        Self.calendar.date(byAdding: .day, value: -days, to: Self.now)!
    }

    private func title(_ date: Date?) -> String {
        HistoryDayGroups.title(for: date, now: Self.now, calendar: Self.calendar)
    }

    @Test func eachViewGoesUnderItsTime() {
        #expect(title(Self.now) == "Today")
        #expect(title(daysAgo(1)) == "Yesterday")
        #expect(title(daysAgo(3)) == "This Week")
        #expect(title(daysAgo(9)) == "Last Week")
        #expect(title(daysAgo(14)) == "This Month")
        #expect(title(daysAgo(20)) == "Last Month")
        #expect(title(daysAgo(80)) == "July")
        #expect(title(daysAgo(400)) == "September 2025")
        #expect(title(nil) == "Earlier")
    }

    @Test func groupsCountThePostsInOrder() {
        let dates: [Date?] = [Self.now, Self.now, daysAgo(1), daysAgo(9), nil]
        #expect(HistoryDayGroups.groups(for: dates, now: Self.now, calendar: Self.calendar) == [
            HistoryGroup(title: "Today", count: 2),
            HistoryGroup(title: "Yesterday", count: 1),
            HistoryGroup(title: "Last Week", count: 1),
            HistoryGroup(title: "Earlier", count: 1)
        ])
    }

    private func post(_ id: String) -> GalleryPost {
        GalleryPost(id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil, caption: id, publishedAtMS: 0)
    }

    /// The pager hands History's page its groups; groups that do not cover
    /// the posts exactly fall back to one list.
    @Test func theHistoryPageIsTitledByDay() {
        let posts = ["a", "b", "c"].map(post)
        let groups = [HistoryGroup(title: "Today", count: 2), HistoryGroup(title: "Yesterday", count: 1)]
        #expect(ProfileGalleryPagerView.pageState(.content(posts), for: .history, groups: groups) == .sections([
            PostGridPageSection(title: "Today", posts: Array(posts[0..<2])),
            PostGridPageSection(title: "Yesterday", posts: [posts[2]])
        ]))
        #expect(ProfileGalleryPagerView.pageState(
            .content(posts), for: .history, groups: [HistoryGroup(title: "Today", count: 2)]
        ) == .content(posts))
    }

    /// Each group carries its own posts' view dates (#2170).
    @Test func eachGroupCarriesItsPostsViewDates() {
        let posts = ["a", "b", "c"].map(post)
        let groups = [HistoryGroup(title: "Today", count: 2), HistoryGroup(title: "Yesterday", count: 1)]
        let dates = [PostID("a"): Self.now, PostID("b"): daysAgo(0), PostID("c"): daysAgo(1)]
        #expect(ProfileGalleryPagerView.pageState(.content(posts), for: .history, groups: groups, viewedAt: dates) == .sections([
            PostGridPageSection(title: "Today", posts: Array(posts[0..<2]), viewedAt: [PostID("a"): Self.now, PostID("b"): daysAgo(0)]),
            PostGridPageSection(title: "Yesterday", posts: [posts[2]], viewedAt: [PostID("c"): daysAgo(1)])
        ]))
    }

    /// History's page offers VoiceOver "Remove from History"; no other
    /// page does. No row swipes (the owner, 2026-11-07).
    @Test func onlyHistorysRowsOfferRemoval() throws {
        let pager = ProfileGalleryPagerView(
            tabs: [.format(.activity), .saved, .history], makePage: TestGridPages.pageMaker()
        )
        var removed: [PostID] = []
        pager.onRemoveFromHistory = { removed.append($0.id) }
        let history = try #require(pager.builtPage(for: .history))
        let action = try #require(history.rowAccessibilityAction)
        #expect(action.title == "Remove from History")
        action.perform(post("x"))
        #expect(removed == [PostID("x")])
        #expect(pager.builtPage(for: .saved)?.rowAccessibilityAction == nil)
    }

    /// A post opened from History holds the page; one opened elsewhere
    /// does not.
    @Test func openingFromHistoryHoldsIt() throws {
        let pager = ProfileGalleryPagerView(
            tabs: [.format(.activity), .history], makePage: TestGridPages.pageMaker()
        )
        var holds = 0
        pager.onHistoryPostOpening = { holds += 1 }
        try #require(pager.builtPage(for: .history)).onPostTapped?(post("a"), [], false)
        try #require(pager.builtPage(for: .format(.activity))).onPostTapped?(post("b"), [], false)
        #expect(holds == 1)
    }

    private actor NoProfiles: ProfileProviding {
        struct Unavailable: Error {}
        func currentUserProfile() async throws -> UserProfile { throw Unavailable() }
        func profile(id: ProfileID) async throws -> UserProfile { throw Unavailable() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { throw Unavailable() }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { throw Unavailable() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { throw Unavailable() }
    }

    private actor HistoryGallery: ProfileGalleryProviding {
        let all: [GalleryPost]
        init(_ all: [GalleryPost]) { self.all = all }
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { ids.compactMap { id in all.first { $0.id.rawValue == id } } }
    }

    private struct NoImages: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    /// The view model hands each post's view date to the page, and a removal
    /// leaves every other post its own (#2170).
    @Test func viewDatesStayWithTheirPostsThroughARemoval() async throws {
        let name = "history-rows-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock(Self.now)
        let store = PostViewHistoryStore(
            defaults: defaults, scope: StorageScope(owner: .member(account: "A", profile: "P")), now: { clock.date }
        )
        var stamps: [String: Date] = [:]
        for (index, id) in ["a", "b", "c"].enumerated() {
            clock.date = Self.now.addingTimeInterval(Double(index - 3) * 3_600)
            stamps[id] = clock.date
            store.record(id)
        }
        let viewModel = ProfileViewModel(
            repository: NoProfiles(), gallery: HistoryGallery(["a", "b", "c"].map(post)), viewHistory: store
        )
        let now = Self.now
        viewModel.now = { now }
        var latest: ProfileViewModel.GallerySnapshot?
        viewModel.onGalleryChange = { latest = $0 }
        viewModel.loadHistory()
        for _ in 0..<200 where latest?.historyViewedAt.count != 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(latest?.historyViewedAt == [PostID("a"): stamps["a"]!, PostID("b"): stamps["b"]!, PostID("c"): stamps["c"]!])

        viewModel.removeFromHistory(PostID("b"))
        for _ in 0..<200 where latest?.historyViewedAt.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(latest?.historyViewedAt == [PostID("a"): stamps["a"]!, PostID("c"): stamps["c"]!])
        if case .content(let posts) = latest?.history {
            #expect(posts.map(\.id.rawValue) == ["c", "a"])
        } else {
            Issue.record("History lost its posts")
        }
    }

    /// The viewer's own profile, three posts in its history, the shell's
    /// balance on its bar, its tabs landed. Tests of History's bar (#2307).
    private struct OwnProfile {
        let screen: ProfileViewController
        let store: PostViewHistoryStore
        /// History's index in the selector.
        let history: Int

        /// The bar's trailing items, outermost first, by what VoiceOver
        /// reads — the gear says "Settings", the balance "Balance".
        var bar: [String] {
            let items: [UIBarButtonItem] = screen.navigationItem.rightBarButtonItems ?? []
            return items.compactMap { item -> String? in item.accessibilityLabel ?? item.title }
        }

        /// The bar's item of that identifier, if it shows one.
        func item(_ id: String) -> UIBarButtonItem? {
            screen.navigationItem.rightBarButtonItems?.first { $0.identifier == id }
        }
    }

    private func ownProfile(defaults: UserDefaults) async throws -> OwnProfile {
        let clock = Clock(Self.now.addingTimeInterval(-3 * 3_600))
        let store = PostViewHistoryStore(
            defaults: defaults, scope: StorageScope(owner: .member(account: "A", profile: "P")), now: { clock.date }
        )
        for id in ["a", "b", "c"] {
            clock.date.addTimeInterval(600)
            store.record(id)
        }
        let viewModel = ProfileViewModel(
            repository: NoProfiles(), gallery: HistoryGallery(["a", "b", "c"].map(post)), viewHistory: store
        )
        let now = Self.now
        viewModel.now = { now }
        let screen = ProfileViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: NoImages()),
            makeGridPage: TestGridPages.factory(), onLogout: {}, trayPlacement: .aboveBottomSafeArea
        )
        screen.loadViewIfNeeded()
        let balance = UIBarButtonItem(title: "250")
        balance.accessibilityLabel = "Balance"
        screen.setTrailingAccessoryItem(balance)
        viewModel.loadHistory()
        for _ in 0..<300 where !screen.debugTabTitles.contains("History") { try await Task.sleep(for: .milliseconds(10)) }
        let history = try #require(screen.debugTabTitles.firstIndex(of: "History"))
        return OwnProfile(screen: screen, store: store, history: history)
    }

    /// The own profile's bar per state (#2307, the owner 2026-11-11): the
    /// gear and the balance at rest on every tab, History included; on
    /// History once the tray has scrolled away, Select in the gear's place;
    /// selecting, Done there, wherever the scroll is. The balance is never
    /// replaced.
    @Test func historysSelectStandsInTheGearsPlaceOnceTheTrayHasGone() async throws {
        let name = "history-bar-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let own = try await ownProfile(defaults: defaults)
        let screen = own.screen

        // At rest, on Posts and on History alike.
        #expect(own.bar == ["Settings", "Balance"], "Posts at rest: \(own.bar)")
        screen.selectTab(at: own.history)
        #expect(own.bar == ["Settings", "Balance"], "History at rest wears Select: \(own.bar)")

        // The tray goes under the bar: Select, in the gear's place, under its
        // own identifier — the bar's morph, not a re-titled gear (R3).
        screen.debugSetTrayScrolledAway(true)
        #expect(own.bar == ["Select", "Balance"], "History, tray away: \(own.bar)")
        #expect(own.item("profile.history.select")?.isEnabled == true)
        #expect(own.item("profile.settings") == nil)

        // Back up: the gear.
        screen.debugSetTrayScrolledAway(false)
        #expect(own.bar == ["Settings", "Balance"], "History, tray back: \(own.bar)")
    }

    /// Done holds while selecting, whatever the scroll — without it there
    /// would be no way out (#2307). After Done, the scroll's rule again.
    @Test func doneHoldsWhileSelectingWhateverTheScroll() async throws {
        let name = "history-done-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let own = try await ownProfile(defaults: defaults)
        let screen = own.screen
        screen.selectTab(at: own.history)
        screen.debugSetTrayScrolledAway(true)

        screen.setSelectingHistory(true)
        #expect(own.bar == ["Done", "Balance"], "selecting, scrolled: \(own.bar)")
        #expect(own.item("profile.history.done")?.style == .prominent)

        // Back to the top: Done stays.
        screen.debugSetTrayScrolledAway(false)
        #expect(screen.isSelectingHistory)
        #expect(own.bar == ["Done", "Balance"], "selecting, at the top: \(own.bar)")

        // Done at the top: the gear. Selecting again and Done scrolled: Select.
        screen.setSelectingHistory(false)
        #expect(own.bar == ["Settings", "Balance"], "after Done, tray in sight: \(own.bar)")
        screen.setSelectingHistory(true)
        #expect(own.bar == ["Done", "Balance"], "selecting from the top: \(own.bar)")
        screen.debugSetTrayScrolledAway(true)
        screen.setSelectingHistory(false)
        #expect(own.bar == ["Select", "Balance"], "after Done, tray away: \(own.bar)")
    }

    /// Select only on History (#2307): another tab with the tray away keeps
    /// the gear; leaving History with the tray away puts the gear back, and
    /// coming back brings Select.
    @Test func selectIsHistorysOnlyWhenTheTrayIsAway() async throws {
        let name = "history-tabs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let own = try await ownProfile(defaults: defaults)
        let screen = own.screen

        // A tab change re-reads the page's real scroll (nil in a test), so
        // the tray's state is stated again after each, as a scroll would.
        screen.debugSetTrayScrolledAway(true)
        #expect(own.bar == ["Settings", "Balance"], "Posts, tray away: \(own.bar)")
        screen.selectTab(at: own.history)
        screen.debugSetTrayScrolledAway(true)
        #expect(own.bar == ["Select", "Balance"], "History, tray away: \(own.bar)")
        screen.selectTab(at: 0)
        screen.debugSetTrayScrolledAway(true)
        #expect(own.bar == ["Settings", "Balance"], "left History, tray away: \(own.bar)")
        screen.selectTab(at: own.history)
        screen.debugSetTrayScrolledAway(true)
        #expect(own.bar == ["Select", "Balance"], "back on History, tray away: \(own.bar)")
    }

    /// Select stays disabled while History is empty (#2307, as #2188).
    @Test func selectIsDisabledWithNoHistory() async throws {
        let name = "history-empty-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let own = try await ownProfile(defaults: defaults)
        let screen = own.screen
        screen.selectTab(at: own.history)
        screen.debugSetTrayScrolledAway(true)
        #expect(own.item("profile.history.select")?.isEnabled == true)

        // The store emptied under the page: Select stays, disabled, and the
        // balance where it is.
        for id in ["a", "b", "c"] { own.store.remove(id) }
        screen.debugRebuildNavigationState()
        #expect(own.bar == ["Select", "Balance"], "\(own.bar)")
        #expect(own.item("profile.history.select")?.isEnabled == false)
        screen.setSelectingHistory(true)
        #expect(!screen.isSelectingHistory, "selected with nothing to select")
    }

    /// History's select mode (the owner, 2026-11-08): selecting, Done in
    /// the gear's place (#2307), and the foot's "Remove from History (n)"
    /// takes the selected rows out and ends the mode. Off History, the
    /// gear, and no select mode.
    @Test func historysSelectModeRemovesTheSelectedRows() async throws {
        let name = "history-select-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let own = try await ownProfile(defaults: defaults)
        let screen = own.screen
        screen.selectTab(at: own.history)
        screen.debugSetTrayScrolledAway(true)

        screen.setSelectingHistory(true)
        #expect(screen.isSelectingHistory)
        #expect(own.bar == ["Done", "Balance"], "\(own.bar)")
        #expect(!screen.debugAllowsPaging, "selecting still pages to the other tabs")
        #expect(screen.debugHistoryPage?.isSelectingRows == true)
        #expect(screen.debugHistoryRemoveTitle == "Remove from History")
        #expect(!screen.debugHistoryRemoveEnabled)

        // Two rows selected: the count, then out they go and the mode ends.
        screen.debugHistoryPage?.onRowSelectionChanged?([PostID("a"), PostID("c")])
        #expect(screen.debugHistoryRemoveTitle == "Remove from History (2)")
        #expect(screen.debugHistoryRemoveEnabled)
        screen.debugTapHistoryRemove()
        #expect(own.store.postIDs == ["b"])
        #expect(!screen.isSelectingHistory)
        #expect(screen.debugHistoryPage?.isSelectingRows == false)
        #expect(own.bar == ["Select", "Balance"], "\(own.bar)")
        #expect(screen.debugAllowsPaging)

        // Off History: the gear and the balance, and no select mode.
        screen.setSelectingHistory(true)
        screen.selectTab(at: 0)
        #expect(!screen.isSelectingHistory)
        #expect(own.bar == ["Settings", "Balance"], "\(own.bar)")
    }

    /// History holds still while the viewer is on it (the owner,
    /// 2026-11-07): views recorded meanwhile wait, a removal applies, and
    /// leaving takes them all in.
    @Test func historyHoldsStillUntilTheViewerLeavesIt() async throws {
        let name = "history-hold-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock(Self.now.addingTimeInterval(-4 * 3_600))
        let store = PostViewHistoryStore(
            defaults: defaults, scope: StorageScope(owner: .member(account: "A", profile: "P")), now: { clock.date }
        )
        for id in ["a", "b", "c"] {
            clock.date.addTimeInterval(600)
            store.record(id)
        }
        let viewModel = ProfileViewModel(
            repository: NoProfiles(), gallery: HistoryGallery(["a", "b", "c", "d"].map(post)), viewHistory: store
        )
        let now = Self.now
        viewModel.now = { now }
        var latest: ProfileViewModel.GallerySnapshot?
        viewModel.onGalleryChange = { latest = $0 }
        func shown() -> [String] {
            if case .content(let posts) = latest?.history { posts.map(\.id.rawValue) } else { [] }
        }
        func settle(on expected: [String]) async throws {
            for _ in 0..<200 where shown() != expected { try await Task.sleep(for: .milliseconds(10)) }
            #expect(shown() == expected)
        }
        viewModel.loadHistory()
        try await settle(on: ["c", "b", "a"])

        // A post opened from History, then two more viewed in its feed.
        viewModel.holdHistory()
        clock.date = Self.now
        store.record("a")
        store.record("d")
        viewModel.loadHistory()
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown() == ["c", "b", "a"], "History moved while the viewer was on it")
        #expect(viewModel.holdsHistory)

        // A removal still applies.
        viewModel.removeFromHistory(PostID("b"))
        try await settle(on: ["c", "a"])

        // Leaving takes in what was viewed.
        viewModel.releaseHistory()
        try await settle(on: ["d", "a", "c"])
        #expect(!viewModel.holdsHistory)

        // A pull on the profile does too, held or not.
        viewModel.holdHistory()
        clock.date.addTimeInterval(60)
        store.record("c")
        viewModel.loadHistory()
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown() == ["d", "a", "c"])
        viewModel.refreshHistory()
        try await settle(on: ["c", "d", "a"])
        #expect(!viewModel.holdsHistory)
    }
}
