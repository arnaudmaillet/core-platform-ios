import CoreModels
import FeedInterface
import Foundation
import PostGrid

/// The vertical feed's OWN list, for a post opened from For You's "For you"
/// section or from its "View all" gallery (#1343, the owner 2026-10-17): the
/// tapped post, then posts read from the discovery pool on a cursor of their
/// own — never the grid's list continued from the tap, and nothing the grid
/// has already shown.
///
/// One cursor for the screen's life: `begin(with:)` hands the feed its first
/// window (the tapped post and what was read ahead), `next(after:)` pages on,
/// and the next opening carries on from where the last one stopped — only a
/// refresh starts the pool over (`reset`). A provider with no discovery answers
/// nothing, and the caller keeps the grid's own window — what it did before.
@MainActor
final class ForYouOwnFeed {
    private let repository: any ForYouProviding
    /// The posts the grid holds right now: never served again.
    private let excluded: () -> Set<PostID>

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

    /// Whether the pool exists at all (discovery wired). Without it there is
    /// no own list, and the caller keeps the grid's window.
    private let isAvailable: () -> Bool

    init(
        repository: any ForYouProviding,
        isAvailable: @escaping () -> Bool = { true },
        excluded: @escaping () -> Set<PostID>
    ) {
        self.repository = repository
        self.isAvailable = isAvailable
        self.excluded = excluded
    }

    /// Reads the next opening's window ahead, so a tap opens on posts already
    /// in hand rather than waiting on the network. Idempotent.
    func prepare() {
        guard readAhead.isEmpty, readAheadTask == nil else { return }
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
        let hidden = excluded().union([tapped.id])
        let ahead = readAhead.filter { !hidden.contains($0.id) }
        readAhead = []
        served.insert(tapped.id)
        guard !ahead.isEmpty else {
            prepare()
            return [tapped]
        }
        served.formUnion(ahead.map(\.id))
        return [tapped] + ahead
    }

    /// The feed's next posts after its window — the continuation. Nil once
    /// the pool is spent. The session's cursor carries on; the next opening
    /// reads ahead a fresh one.
    func next(after _: PostID) async -> [PostID]? {
        // A read ahead still on its way is the next window: waited for, never
        // read twice on the same cursor.
        if let pending = readAheadTask { await pending.value }
        var posts = readAhead.filter { !served.contains($0.id) && !excluded().contains($0.id) }
        readAhead = []
        if posts.isEmpty { posts = await read(Self.windowSize, skipping: served) }
        guard !posts.isEmpty else { return nil }
        served.formUnion(posts.map(\.id))
        return posts.map(\.id)
    }

    /// The feed closed: the next opening carries on from where this one
    /// stopped, read ahead now.
    ///
    /// ⚠️ THE CURSOR CARRIES ON, it does not start over (the owner,
    /// 2026-10-17, filmed): starting over replayed the same posts after the
    /// tapped one on every opening. What was served stays served, so the
    /// next window is posts the viewer has not been shown yet.
    func end() {
        prepare()
    }

    /// A new corpus (a refresh): the pool starts over.
    func reset() {
        readAheadTask?.cancel()
        readAheadTask = nil
        readAhead = []
        cursor = .start
        served = []
        prepare()
    }

    /// Up to `count` posts from the pool, past the grid's and `skipping`.
    private func read(_ count: Int, skipping: Set<PostID>) async -> [GalleryPost] {
        var found: [GalleryPost] = []
        var pages = 0
        while found.count < count, pages < Self.maxPagesPerRead, cursor != .end {
            pages += 1
            let page: ForYouPage?
            switch cursor {
            case .start: page = try? await repository.discoveryFirstPage()
            case .token(let token): page = try? await repository.discoveryPage(after: token)
            case .end: page = nil
            }
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
