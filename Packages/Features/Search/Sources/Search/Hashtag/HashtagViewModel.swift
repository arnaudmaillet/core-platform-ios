import CoreModels
import DesignSystem
import Foundation

/// The posts carrying one `#tag` (#524), laid out like For You (#629): its
/// top posts as the page's list, its newest as a row above it, and how many
/// there are — each page by page as the viewer scrolls (#579).
///
/// ⚠️ FROM `search.v1`, until a posts-by-tag endpoint exists: a `#tag` query
/// over posts, sorted by POPULARITY for Top and RECENCY for Recent. The
/// engine indexes a post's tags with its caption, so a loose match is
/// possible on the fleet; the count is the tag's own (`HashtagHit`).
@MainActor
final class HashtagViewModel {
    enum Tab: CaseIterable {
        /// The page's list, ranked: For You's "For you" slot. Every post — a
        /// text post is a card, and the list tiles media into its mosaic
        /// slices itself.
        case top
        /// Newest first: the row above the list, and the whole list its title
        /// opens — For You's "Following" slot.
        case recent

        var sort: SearchSortOrder { self == .top ? .popularity : .recency }
    }

    /// What the row and the list are called.
    ///
    /// ⚠️ "TOP", NOT "TRENDING", until the backend ranks by trend
    /// (core-platform-backend#830): today the sort is search POPULARITY,
    /// relevance on the fleet and all-time engagement once wired. Decided by
    /// the owner, 2026-10-07. "Recent", not "New": "New" in this app means
    /// unseen since the last visit.
    static let rowTitle = "Recent"
    static let listTitle = "Top"
    /// How many of the newest posts the row shows — For You's Following row's
    /// number (`ForYouViewModel.railLimit`).
    static let rowLimit = 20

    /// The tag, lowercased and without its `#`.
    let tag: String
    private(set) var top: SearchPostSurfaceState = .loading
    private(set) var recent: SearchPostSurfaceState = .loading
    /// What Recent found when it fits in one page — every post there is —
    /// else the index's coarse count; nil until either is known.
    private(set) var postCount: Int?
    var onChange: (() -> Void)?

    /// Six rows of a three-column gallery.
    static let pageSize: Int32 = 18

    private let repository: any SearchProviding

    /// Where each tab is: the posts shown, where the next page starts (nil
    /// when there is none), and whether one is being fetched.
    private struct Paging {
        var ids: [PostID] = []
        var nextPageToken: String?
        var isLoading = false
    }
    private var paging: [Tab: Paging] = [:]

    init(tag: String, repository: any SearchProviding) {
        let bare = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        self.tag = bare.lowercased()
        self.repository = repository
    }

    /// `#tag`, as the screen and its empty states name it.
    var title: String { "#" + tag }

    /// "1 post", "12 posts", "1.2K posts".
    var countText: String? {
        postCount.map { $0 == 1 ? "1 post" : "\(CountFormatter.compactString(for: $0)) posts" }
    }

    func state(of tab: Tab) -> SearchPostSurfaceState { tab == .top ? top : recent }

    /// The row above the list: the newest posts, at most `rowLimit` — or
    /// nothing while Recent is still loading, empty or failed (the list says
    /// those for the page).
    var recentRow: SearchPostSurfaceState {
        guard case .posts(let ids) = recent else { return .empty(query: title) }
        return .posts(Array(ids.prefix(Self.rowLimit)))
    }

    /// Whether `tab` is fetching its next page — the footer spinner.
    /// Whether `tab` has a page past what it shows (#638).
    func hasMore(_ tab: Tab) -> Bool {
        paging[tab]?.nextPageToken != nil
    }

    func isLoadingMore(_ tab: Tab) -> Bool {
        paging[tab]?.isLoading == true && !(paging[tab]?.ids.isEmpty ?? true)
    }

    /// The first page of both tabs, and the count.
    func load() async {
        paging = [:]
        top = .loading
        recent = .loading
        onChange?()
        async let count = try? await repository.hashtagPostCount(tag)
        async let topDone: Void = loadPage(.top, first: true)
        async let recentDone: Void = loadPage(.recent, first: true)
        _ = await (topDone, recentDone)
        if postCount == nil, let counted = await count { postCount = counted }
        onChange?()
    }

    /// The next page of `tab`, when the viewer nears its end: one request at a
    /// time, none once the server says there is no more, and a failure keeps
    /// what is shown and is tried again on the next approach.
    func loadMore(_ tab: Tab) async {
        guard let state = paging[tab], !state.isLoading, state.nextPageToken != nil else { return }
        await loadPage(tab, first: false)
    }

    private func loadPage(_ tab: Tab, first: Bool) async {
        var state = paging[tab] ?? Paging()
        guard !state.isLoading, first ? state.ids.isEmpty : state.nextPageToken != nil else { return }
        state.isLoading = true
        paging[tab] = state
        if !first { onChange?() }
        let page: PostSearchPage
        do {
            page = try await repository.searchPostsPage(
                matching: title, sort: tab.sort, limit: Self.pageSize,
                pageToken: first ? nil : state.nextPageToken
            )
        } catch {
            paging[tab]?.isLoading = false
            if paging[tab]?.ids.isEmpty ?? true {
                set(tab, .failed(message: "Couldn\u{2019}t load \(title)."))
            }
            onChange?()
            return
        }
        // Every post: the list draws a text post as a card (#629), so there
        // is no page to skip for want of a picture.
        let known = Set(state.ids)
        state.ids += page.hits.map(\.id).filter { !known.contains($0) }
        state.nextPageToken = page.nextPageToken
        state.isLoading = false
        paging[tab] = state
        #if DEBUG
        // What QA reads with `log show`: one line per page landed.
        NSLog("[hashtag] %@ %@ +%d → %d, next=%@", title, "\(tab)", page.hits.count, state.ids.count,
              page.nextPageToken ?? "none")
        #endif
        if tab == .recent, first, page.nextPageToken == nil {
            // A first page with no next one is every post there is.
            postCount = page.hits.count
        }
        set(tab, state.ids.isEmpty ? .empty(query: title) : .posts(state.ids))
        onChange?()
    }

    private func set(_ tab: Tab, _ state: SearchPostSurfaceState) {
        switch tab {
        case .top: top = state
        case .recent: recent = state
        }
    }
}
