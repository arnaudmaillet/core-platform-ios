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
/// One session per opening: `begin(with:)` hands the feed its first window
/// (the tapped post and what was read ahead), `next(after:)` pages on, and the
/// next opening starts a fresh cursor. A provider with no discovery answers
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

    init(repository: any ForYouProviding, excluded: @escaping () -> Set<PostID>) {
        self.repository = repository
        self.excluded = excluded
    }

    /// Reads the next opening's window ahead, so a tap opens on posts already
    /// in hand rather than waiting on the network. Idempotent.
    func prepare() {
        guard readAhead.isEmpty, readAheadTask == nil else { return }
        readAheadTask = Task { [weak self] in
            guard let self else { return }
            defer { readAheadTask = nil }
            readAhead = await read(Self.windowSize, skipping: [])
        }
    }

    /// The feed's first window for `tapped`: the tapped post, then the posts
    /// read ahead. Nil when there are none — no discovery, or nothing beyond
    /// the grid — and the caller keeps the grid's own window.
    func begin(with tapped: GalleryPost) -> [GalleryPost]? {
        let hidden = excluded().union([tapped.id])
        let ahead = readAhead.filter { !hidden.contains($0.id) }
        readAhead = []
        guard !ahead.isEmpty else {
            prepare()
            return nil
        }
        served = Set(ahead.map(\.id)).union([tapped.id])
        return [tapped] + ahead
    }

    /// The feed's next posts after its window — the continuation. Nil once
    /// the pool is spent. The session's cursor carries on; the next opening
    /// reads ahead a fresh one.
    func next(after _: PostID) async -> [PostID]? {
        let posts = await read(Self.windowSize, skipping: served)
        guard !posts.isEmpty else { return nil }
        served.formUnion(posts.map(\.id))
        return posts.map(\.id)
    }

    /// The session is over (the feed closed): the next opening starts a
    /// fresh cursor, read ahead now.
    func end() {
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
