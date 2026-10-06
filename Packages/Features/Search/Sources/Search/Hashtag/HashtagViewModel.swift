import CoreModels
import DesignSystem
import Foundation

/// The posts carrying one `#tag` (#524): its most liked with a picture, and
/// all of them newest first, and how many there are — each tab page by page
/// as the viewer scrolls (#579).
///
/// ⚠️ FROM `search.v1`, until a posts-by-tag endpoint exists: a `#tag` query
/// over posts, sorted by POPULARITY for Top and RECENCY for Recent. The
/// engine indexes a post's tags with its caption, so a loose match is
/// possible on the fleet; the count is the tag's own (`HashtagHit`).
@MainActor
final class HashtagViewModel {
    enum Tab: CaseIterable {
        /// The gallery, so posts WITH a picture — a text post has no tile.
        case top
        /// Every post, cards, newest first.
        case recent

        var sort: SearchSortOrder { self == .top ? .popularity : .recency }
    }

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
    /// How many pages Top reads in a row to find posts with a picture before
    /// it waits for the viewer again: a page of text posts adds no tile, so
    /// the end the viewer reached would not move.
    static let maxEmptyHops = 3

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

    /// Whether `tab` is fetching its next page — the footer spinner.
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
        var hops = 0
        while true {
            var state = paging[tab] ?? Paging()
            guard !state.isLoading, first ? state.ids.isEmpty : state.nextPageToken != nil else { return }
            state.isLoading = true
            paging[tab] = state
            if !first { onChange?() }
            let page: PostSearchPage
            do {
                page = try await repository.searchPostsPage(
                    matching: title, sort: tab.sort, limit: Self.pageSize,
                    pageToken: first && hops == 0 ? nil : state.nextPageToken
                )
            } catch {
                paging[tab]?.isLoading = false
                if paging[tab]?.ids.isEmpty ?? true {
                    set(tab, .failed(message: "Couldn\u{2019}t load \(title)."))
                }
                onChange?()
                return
            }
            var added = page.hits
            if tab == .top { added = added.filter(\.hasMedia) }
            let known = Set(state.ids)
            state.ids += added.map(\.id).filter { !known.contains($0) }
            state.nextPageToken = page.nextPageToken
            state.isLoading = false
            paging[tab] = state
            #if DEBUG
            // What QA reads with `log show`: one line per page landed.
            NSLog("[hashtag] %@ %@ +%d → %d, next=%@", title, "\(tab)", added.count, state.ids.count,
                  page.nextPageToken ?? "none")
            #endif
            if tab == .recent, first, hops == 0, page.nextPageToken == nil {
                // A first page with no next one is every post there is.
                postCount = page.hits.count
            }
            // A page that added nothing to Top (all text) moves no end the
            // viewer could reach: read on, a few pages at most.
            let readsOn = tab == .top && added.isEmpty && page.nextPageToken != nil
                && hops + 1 < Self.maxEmptyHops
            if !state.ids.isEmpty {
                set(tab, .posts(state.ids))
            } else if !readsOn {
                set(tab, .empty(query: title))
            }
            onChange?()
            hops += 1
            guard readsOn else { return }
        }
    }

    private func set(_ tab: Tab, _ state: SearchPostSurfaceState) {
        switch tab {
        case .top: top = state
        case .recent: recent = state
        }
    }
}
