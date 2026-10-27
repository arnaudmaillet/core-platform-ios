import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import HeroPage
import MediaCore
import PostGrid
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
    /// What a row's "..." offers — see `PostGridPage.postMenuActions`.
    /// The tab is the page's: History adds its own row (#1344).
    var authorMenuActions: ((PostGridAuthorMenuContext, ProfileTab) -> [PostCardMenuAction])?

    /// - Parameter makePage: For You's own grid page, in a style (#1273,
    ///   epic #1269): every page of the profile is For You's, its tiles For
    ///   You's tiles.
    init(
        tabs: [ProfileTab] = ProfileTab.publicTabs,
        makePage: (PostGridPageStyle) -> any PostGridPage
    ) {
        let built = tabs.map { tab in
            let page = makePage(ProfileGalleryPagerView.style(for: tab))
            // Post info by size on every tile (`PostTileInfo`'s three
            // levels) — the one tile contract.
            page.showsTileInfo = true
            return page
        }
        super.init(tabs: tabs, pages: built)
        for (tab, page) in zip(allTabs, allPages) {
            page.onPostTapped = { [weak self] post, stream, comments in
                guard let self else { return }
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
            page.postMenuActions = { [weak self] context in
                self?.authorMenuActions?(context, tab) ?? []
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The shape a tab's page takes.
    static func style(for tab: ProfileTab) -> PostGridPageStyle {
        switch tab {
        // History lays out like For You (the owner, 2026-10-17): cards,
        // mosaic chunks and tiles.
        case .format(.activity), .reposts, .tagged, .history: .discover
        case .format(.media): .grid
        case .format(.short), .saved, .reactions: .list
        }
    }

    func render(_ snapshot: ProfileViewModel.GallerySnapshot) {
        for (index, tab) in allTabs.enumerated() {
            // Whether more pages are coming decides the Discover list's tail
            // chunk, so it is told before the posts.
            allPages[index].setCorpusComplete(snapshot.isComplete(for: tab))
            allPages[index].show(Self.pageState(
                snapshot.state(for: tab), for: tab,
                groups: tab == .history ? snapshot.historyGroups : []
            ))
        }
    }

    /// A profile page's state, as the page draws it: the tab's own words
    /// for an empty page, the lock for a private profile, the failure.
    ///
    /// `groups` title the posts in order (History's days, #1344) — dropped
    /// unless they cover the posts exactly.
    ///
    /// A private profile's page with posts (Tagged) is drawn like any other:
    /// no lock line above them (#1445). The lock is the state of a page with
    /// nothing to show, and never a tab of its own.
    static func pageState(
        _ state: ProfileViewModel.GalleryPageState, for tab: ProfileTab, groups: [HistoryGroup] = []
    ) -> PostGridPageState {
        switch state {
        case .loading:
            return .loading
        case .content(let posts):
            guard !groups.isEmpty, groups.reduce(0, { $0 + $1.count }) == posts.count else {
                return .content(posts)
            }
            var start = 0
            return .sections(groups.map { group in
                defer { start += group.count }
                return PostGridPageSection(title: group.title, posts: Array(posts[start..<start + group.count]))
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
