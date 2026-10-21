import CoreModels
import FeedInterface
import Foundation
import PostGrid

/// The vertical feed's OWN list, for a post opened from For You's "For you"
/// section or from its "View all" gallery (#1343, the owner 2026-10-17): the
/// tapped post, then posts read from the discovery pool on a cursor of their
/// own — never the grid's list continued from the tap. What lies past the
/// grid comes first; the grid's own posts follow once the pool is spent
/// (#1511), so a grid that has loaded the whole pool never cuts a feed short.
///
/// One cursor for the screen's life: `begin(with:)` hands the feed its first
/// window (the tapped post and what was read ahead), `next(after:)` pages on,
/// and the next opening carries on from where the last one stopped — a
/// refresh starts the pool over (`reset`), and so does an opening that finds
/// the pool spent (#1496). A provider with no discovery answers nothing, and
/// the caller keeps the grid's own window — what it did before.
///
/// ⚠️ ONLY THE SERVER ENDS THE LIST (#1496, the owner 2026-10-20): an empty
/// `next_page_token`. A page that failed, or a read that ran out of pages
/// while a token remains, is "nothing yet" — `next(after:)` answers `[]`, the
/// feed keeps its place and asks again on its next approach — never `nil`.
@MainActor
final class ForYouOwnFeed {
    private let repository: any ForYouProviding
    /// The posts the grid holds right now, in its order: skipped while the
    /// pool past them lasts, served after it (#1511).
    private let grid: () -> [GalleryPost]
    private func excluded() -> Set<PostID> { Set(grid().map(\.id)) }

    /// How many posts a window carries ahead of the tapped one.
    static let windowSize = 12
    /// Pages one read may skip through before it gives up — the pool's head is
    /// the grid's, so the first pages are mostly excluded.
    static let maxPagesPerRead = 4

    /// Where the session's cursor stands: nil before its first page, `.end`
    /// once the pool is spent.
    private enum Cursor: Equatable { case start, token(String), end }
    private var cursor: Cursor = .start
    /// Everything this session has handed out.
    private var served: Set<PostID> = []
    /// Read ahead for the next opening.
    private var readAhead: [GalleryPost] = []
    private var readAheadTask: Task<Void, Never>?

    /// What this opening handed the feed, in order, and when it began —
    /// what `end()` checks against the viewer's history.
    private var opening: [GalleryPost] = []
    private var openedAt: Date?
    /// Handed out but never viewed: the next opening serves these first.
    private var returned: [GalleryPost] = []
    /// The posts viewed since a moment — the history every vertical feed
    /// records into (#1344). Nil: everything handed out counts as seen.
    private let viewedSince: ((Date) -> Set<PostID>)?
    private let now: () -> Date

    /// Whether the pool exists at all (discovery wired). Without it there is
    /// no own list, and the caller keeps the grid's window.
    private let isAvailable: () -> Bool

    init(
        repository: any ForYouProviding,
        isAvailable: @escaping () -> Bool = { true },
        viewedSince: ((Date) -> Set<PostID>)? = nil,
        now: @escaping () -> Date = Date.init,
        grid: @escaping () -> [GalleryPost]
    ) {
        self.repository = repository
        self.isAvailable = isAvailable
        self.viewedSince = viewedSince
        self.now = now
        self.grid = grid
    }

    /// Reads the next opening's window ahead, so a tap opens on posts already
    /// in hand rather than waiting on the network. Idempotent.
    func prepare() {
        // A spent pool reads nothing ahead: the next opening starts a new
        // pass (`begin`), which a read already on its way would hold back.
        guard readAhead.isEmpty, readAheadTask == nil, cursor != .end else { return }
        readAheadTask = Task { [weak self] in
            guard let self else { return }
            defer { readAheadTask = nil }
            readAhead = await read(Self.windowSize, skipping: served)
        }
    }

    /// The feed's first window for `tapped`: the tapped post, then the posts
    /// read ahead. Nil when there are none — no discovery, or nothing beyond
    /// the grid — and the caller keeps the grid's own window.
    ///
    /// ⚠️ THE OWN LIST EVEN BEFORE ITS FIRST READ HAS LANDED (the owner,
    /// 2026-10-17, filmed): a tap made before the read ahead came back fell
    /// back to the grid's window — the first opening after launch replayed
    /// the For You order. It now opens on the tapped post alone, and the
    /// feed's continuation brings the own posts as soon as they are read.
    func begin(with tapped: GalleryPost) -> [GalleryPost]? {
        guard isAvailable() else { return nil }
        // ⚠️ A SPENT POOL STARTS A NEW PASS (#1496, the owner 2026-10-20):
        // every post served stayed served past the end, so the next opening
        // held the tapped post alone, at its end at once. While unseen posts
        // remain the cursor carries on (#1347); once the server has said
        // "no more", the opening reads the pool from its start again — still
        // past the grid's posts — with only the tapped one served.
        // Posts handed out and never viewed are not spent.
        if cursor == .end, readAhead.isEmpty, readAheadTask == nil, returned.isEmpty {
            cursor = .start
            served = []
        }
        // ⚠️ WHAT WAS NEVER VIEWED COMES FIRST (#1511, the owner 2026-10-21,
        // filmed): the window is handed out ahead of the viewer, so a post
        // only glimpsed (a swipe not carried through) counted as served, and
        // the next opening skipped it. As on TikTok or Reels, only a post
        // viewed is spent.
        let back = returned.filter { $0.id != tapped.id }
        returned = []
        let hidden = excluded().union([tapped.id]).union(back.map(\.id))
        let ahead = back + readAhead.filter { !hidden.contains($0.id) }
        readAhead = []
        served.insert(tapped.id)
        served.formUnion(ahead.map(\.id))
        opening = [tapped] + ahead
        openedAt = now()
        guard !ahead.isEmpty else {
            prepare()
            return [tapped]
        }
        return [tapped] + ahead
    }

    /// The feed's next posts after its window — the continuation: the pool
    /// past the grid, and the grid's posts whenever a read finds none
    /// (#1511). Nil once the server has said the pool is spent and the grid's
    /// posts are served; `[]` when nothing could be read right now (a failed
    /// page, a run of excluded pages with a token left), so the feed asks
    /// again rather than ending (#1496). The session's cursor carries on; the
    /// next opening reads ahead a fresh one.
    func next(after _: PostID) async -> [PostID]? {
        // A read ahead still on its way is the next window: waited for, never
        // read twice on the same cursor.
        if let pending = readAheadTask { await pending.value }
        let hidden = served.union(excluded())
        var posts = readAhead.filter { !hidden.contains($0.id) }
        readAhead = []
        if posts.isEmpty { posts = await read(Self.windowSize, skipping: served) }
        guard posts.isEmpty else {
            served.formUnion(posts.map(\.id))
            opening += posts
            return posts.map(\.id)
        }
        // ⚠️ THEN THE GRID'S POSTS, BEFORE THE END (#1511, the owner
        // 2026-10-21): the grid pages the same pool, and once it held all of
        // it nothing lay past it — a tile tapped at the grid's foot opened a
        // feed of two posts. With nothing past the grid in hand, the opening
        // carries on through the grid's posts it has not served, in the
        // grid's order, once each.
        //
        // ⚠️ NOT ONLY ONCE THE POOL IS SPENT: a new pass starts at the pool's
        // head, which is the grid's, and its reads came back empty — "nothing
        // yet" — for several asks. The feed held the tapped post alone, and
        // the first upward swipe closed it (#761; filmed by the owner). What
        // lies past the grid still comes as the reads find it.
        let tail = Array(grid().filter { !served.contains($0.id) }.prefix(Self.windowSize))
        guard tail.isEmpty else {
            served.formUnion(tail.map(\.id))
            opening += tail
            return tail.map(\.id)
        }
        return cursor == .end ? nil : []
    }

    /// The feed closed: the next opening carries on from where this one
    /// stopped, read ahead now.
    ///
    /// ⚠️ THE CURSOR CARRIES ON, it does not start over (the owner,
    /// 2026-10-17, filmed): starting over replayed the same posts after the
    /// tapped one on every opening. What was viewed stays served, so the
    /// next window is posts the viewer has not been shown yet — starting with
    /// those this opening handed out past the furthest one viewed (#1511).
    func end() {
        returnUnviewed()
        prepare()
    }

    /// Puts back what this opening handed out past the furthest post the
    /// viewer viewed. Without a history, everything handed out is spent.
    private func returnUnviewed() {
        defer {
            opening = []
            openedAt = nil
        }
        guard let viewedSince, let openedAt, !opening.isEmpty else { return }
        let viewed = viewedSince(openedAt)
        // The tapped post is the first page on screen, viewed or not.
        let furthest = opening.lastIndex { viewed.contains($0.id) } ?? 0
        let unviewed = Array(opening[(furthest + 1)...])
        served.subtract(unviewed.map(\.id))
        returned = unviewed
    }

    /// A new corpus (a refresh): the pool starts over.
    func reset() {
        readAheadTask?.cancel()
        readAheadTask = nil
        readAhead = []
        cursor = .start
        served = []
        opening = []
        openedAt = nil
        returned = []
        prepare()
    }

    /// Up to `count` posts from the pool, past the grid's and `skipping`.
    ///
    /// ⚠️ A FAILED PAGE LEAVES THE CURSOR WHERE IT WAS (#1496): it used to be
    /// read as the end of the pool, and one timeout ended the list until a
    /// refresh. The read stops; the next one asks for the same page.
    private func read(_ count: Int, skipping: Set<PostID>) async -> [GalleryPost] {
        var found: [GalleryPost] = []
        var pages = 0
        while found.count < count, pages < Self.maxPagesPerRead, cursor != .end {
            pages += 1
            let page: ForYouPage?
            do {
                switch cursor {
                case .start: page = try await repository.discoveryFirstPage()
                case .token(let token): page = try await repository.discoveryPage(after: token)
                case .end: page = nil
                }
            } catch {
                return found
            }
            // No discovery behind the provider: there is no pool to page.
            guard let page else {
                cursor = .end
                break
            }
            cursor = page.nextPageToken.map(Cursor.token) ?? .end
            let hidden = excluded().union(skipping).union(found.map(\.id))
            found += page.posts.filter { !hidden.contains($0.id) }
        }
        // All of it, not `prefix(count)`: the cursor is past these pages, and
        // a post cut here would never be read again.
        return found
    }

    #if DEBUG
    /// What a test reads.
    var debugReadAhead: [PostID] { readAhead.map(\.id) }
    #endif
}
