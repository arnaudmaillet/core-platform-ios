import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import HeroPage
import MediaCore
import PostGrid
import ProfileSettings
import UIKit

/// The profile's pager: its pages (Posts, and on the viewer's own Saved and
/// Liked) on the hero page's pager (`HeroPagePager`, #1653), keyed by its
/// tabs. Anyone else's profile has the one page, Posts (#631).
///
/// What makes the pages one surface — one viewport each, the shared offset
/// below the dock line, the scrub, the detents — is the hero page's; what this
/// adds is what the profile's pages SHOW: their styles, their gallery, their
/// taps, menus and paging.
final class ProfileGalleryPagerView: HeroPagePager<ProfileTab> {
    var onItemTapped: ((GalleryPost, _ stream: [GalleryPost]) -> Void)?
    /// A card's comment chip — see `PostGridPage.onPostTapped`.
    var onItemCommentsTapped: ((GalleryPost, _ stream: [GalleryPost]) -> Void)?
    /// Handed to every page — one screen, one undo window.
    var staking: PostCardStaking? {
        didSet { allPages.forEach { $0.staking = staking } }
    }

    /// Every page's rows ask their "..." again — see
    /// `PostGridPage.refreshAuthorMenus`.
    func refreshAuthorMenus() {
        allPages.forEach { $0.refreshAuthorMenus() }
    }
    /// The page on screen neared its end — only the format pages, whose
    /// corpora page (#634). Saved and Liked are lists the client already holds.
    var onNearEnd: (() -> Void)?
    /// "View all" under one of Posts' mosaic chunks (#631).
    var onViewAllTapped: (() -> Void)?
    /// A failed page's Try Again (#1767): the gallery loads again.
    var onRetry: (() -> Void)?
    /// A row's author was tapped, on whichever page is showing.
    var onAuthorTapped: ((GalleryPost) -> Void)?
    /// A History row's author tapped: the profile card (#2145); the hold
    /// is `onAuthorTapped`.
    var onAuthorCardTapped: ((GalleryPost) -> Void)?
    /// A History row taken out of the history by VoiceOver's action (#2170).
    var onRemoveFromHistory: ((GalleryPost) -> Void)?
    /// A post is about to open from the History page (#2170): History holds
    /// still until the viewer leaves it.
    var onHistoryPostOpening: (() -> Void)?
    /// What a row's "..." offers — see `PostGridPage.postMenuActions`.
    /// The tab is the page's: History adds its own row (#1344).
    var authorMenuActions: ((PostGridAuthorMenuContext, ProfileTab) -> [PostCardMenuAction])?

    /// - Parameters:
    ///   - shown: the tabs on show from the start; every tab when nil. A
    ///     tab's page is built the first time it is shown (#2125): a push
    ///     opens on Posts alone, and the sources with nothing in them — most
    ///     of someone else's — never build theirs.
    ///   - makePage: For You's own grid page, in a style (#1273, epic #1269):
    ///     every page of the profile's POSTS is For You's, its tiles For
    ///     You's tiles.
    ///   - makeChannelsPage: the Channels tab's page (#2232) — a list of
    ///     channels, not posts. Nil (no channels) builds it as a grid page,
    ///     which only a test whose tabs name Channels ever does.
    init(
        tabs: [ProfileTab] = ProfileTab.publicTabs,
        shown: [ProfileTab]? = nil,
        makeChannelsPage: (() -> any PostGridPage)? = nil,
        makePage: @escaping (PostGridPageStyle) -> any PostGridPage
    ) {
        super.init(tabs: tabs, shown: shown) { tab in
            if tab == .channels, let makeChannelsPage { return makeChannelsPage() }
            let page = makePage(ProfileGalleryPagerView.style(for: tab))
            // Post info by size on every tile (`PostTileInfo`'s three
            // levels) — the one tile contract.
            page.showsTileInfo = true
            return page
        }
    }

    override func didBuildPage(_ page: any PostGridPage, for tab: ProfileTab) {
        page.onPostTapped = { [weak self] post, stream, comments in
            guard let self else { return }
            // Before the open: the viewer stays on History while the post is up.
            if tab == .history { onHistoryPostOpening?() }
            if comments, let onItemCommentsTapped {
                onItemCommentsTapped(post, stream)
            } else {
                onItemTapped?(post, stream)
            }
        }
        // Every page that pages: the format pages and, on someone else's
        // profile, Reposts and Tagged (#696). Saved and Liked do not.
        if tab.pages {
            page.onNearEnd = { [weak self, weak page] in
                guard let self, let page, isActive(page) else { return }
                onNearEnd?()
            }
        }
        page.onViewAllTapped = { [weak self] in self?.onViewAllTapped?() }
        page.onRefresh = { [weak self] in self?.onRetry?() }
        page.onAuthorTapped = { [weak self] post in self?.onAuthorTapped?(post) }
        page.onAuthorCardTapped = { [weak self] post in self?.onAuthorCardTapped?(post) }
        // History's rows offer VoiceOver the menu's "Remove from History"
        // (#2170). No swipe: the owner kept it in the menu (2026-11-07).
        if tab == .history {
            page.rowAccessibilityAction = PostGridRowAction(
                title: "Remove from History"
            ) { [weak self] post in self?.onRemoveFromHistory?(post) }
        }
        page.postMenuActions = { [weak self] context in
            self?.authorMenuActions?(context, tab) ?? []
        }
        // A page built late is told what its elders were.
        page.staking = staking
        if let lastSnapshot, tab != .channels { show(lastSnapshot, for: tab, on: page, screen: presenceScreen()) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The shape a tab's page takes.
    static func style(for tab: ProfileTab) -> PostGridPageStyle {
        switch tab {
        // One post per row, by day (the owner, 2026-11-07, #2170) — it laid
        // out like For You since 2026-10-17.
        case .history: .rows
        case .format(.activity), .reposts, .tagged: .discover
        case .format(.media): .grid
        case .format(.short), .saved, .reactions: .list
        // Its own page, not a grid (`ProfileChannelsPage`); a list if asked.
        case .channels: .list
        }
    }

    /// The profile's presence key (`ProfileViewModel.presenceScreen`), asked
    /// at each render: nil leaves every tab its bones.
    var presenceScreen: () -> String? = { nil }
    var presence: SectionPresenceStore = .shared
    /// What the pages were last shown, for a page built after it.
    private var lastSnapshot: ProfileViewModel.GallerySnapshot?

    func render(_ snapshot: ProfileViewModel.GallerySnapshot) {
        lastSnapshot = snapshot
        let screen = presenceScreen()
        // Channels' presence is its model's to remember (#2232): the
        // snapshot holds posts, and says nothing about channels.
        for tab in allTabs where tab != .channels {
            let state = snapshot.state(for: tab)
            let section = String(describing: tab)
            // Every tab's count, built or not: it decides the bones the tab
            // gets when it is.
            if let screen {
                switch state {
                case .content(let posts): presence.remember(posts.count, screen: screen, section: section)
                case .empty: presence.remember(0, screen: screen, section: section)
                default: break
                }
            }
        }
        for (tab, page) in builtPages where tab != .channels { show(snapshot, for: tab, on: page, screen: screen) }
    }

    /// The pages built so far, with their tabs.
    private var builtPages: [(ProfileTab, any PostGridPage)] {
        allTabs.compactMap { tab in builtPage(for: tab).map { (tab, $0) } }
    }

    private func show(
        _ snapshot: ProfileViewModel.GallerySnapshot, for tab: ProfileTab, on page: any PostGridPage,
        screen: String?
    ) {
        // Whether more pages are coming decides the Discover list's tail
        // chunk, so it is told before the posts.
        page.setCorpusComplete(snapshot.isComplete(for: tab))
        let section = String(describing: tab)
        page.show(Self.pageState(
            snapshot.state(for: tab), for: tab,
            groups: tab == .history ? snapshot.historyGroups : [],
            viewedAt: tab == .history ? snapshot.historyViewedAt : [:],
            remembered: screen.flatMap { presence.count(screen: $0, section: section) }
        ))
    }

    /// A profile page's state, as the page draws it: the tab's own words
    /// for an empty page, the lock for a private profile, the failure.
    ///
    /// `groups` title the posts in order (History's days, #1344) — dropped
    /// unless they cover the posts exactly. `viewedAt` dates them (#2170):
    /// each group carries its own posts' dates.
    ///
    /// A private profile's page with posts (Tagged) is drawn like any other:
    /// no lock line above them (#1445). The lock is the state of a page with
    /// nothing to show, and never a tab of its own.
    ///
    /// ⚠️ SECTIONS BY PRESENCE (#1773): `remembered`, the tab's count last
    /// time. A tab that was empty then gets no bones that would turn into its
    /// empty page — nothing, then the answer fades in.
    static func pageState(
        _ state: ProfileViewModel.GalleryPageState, for tab: ProfileTab, groups: [HistoryGroup] = [],
        viewedAt: [PostID: Date] = [:], remembered: Int? = nil
    ) -> PostGridPageState {
        switch state {
        case .loading:
            return remembered == 0 ? .content([]) : .loading
        case .content(let posts):
            guard !groups.isEmpty, groups.reduce(0, { $0 + $1.count }) == posts.count else {
                return .content(posts)
            }
            var start = 0
            return .sections(groups.map { group in
                defer { start += group.count }
                let members = Array(posts[start..<start + group.count])
                let ids = Set(members.map(\.id))
                return PostGridPageSection(
                    title: group.title, posts: members, viewedAt: viewedAt.filter { ids.contains($0.key) }
                )
            })
        case .empty(let message):
            let copy = tab.emptyState
            return .status(PostGridPageStatus(
                symbolName: copy.symbol, title: copy.title,
                subtitle: message.isEmpty ? copy.subtitle : message
            ))
        case .restricted(let title, let message):
            return .status(PostGridPageStatus(symbolName: "lock", title: title, subtitle: message))
        case .failed(let message):
            // A failure is NOT an empty state: the glyph and the headline read
            // as "this did not work", not as "there is nothing here". And it
            // has a way out (#1767): the pull lived on a page whose posts the
            // failure had taken away.
            return .status(PostGridPageStatus(
                symbolName: "exclamationmark.triangle", title: "Couldn't Load", subtitle: message,
                actionTitle: "Try Again"
            ))
        }
    }

    #if DEBUG
    var debugActiveFormat: ProfileTab { debugActiveTab }
    #endif
}
