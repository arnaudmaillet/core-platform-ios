import CoreModels
import Foundation

/// The Popular tab's stream (#2007): a post's comments in the server's
/// popularity order (`ListTopLevel` POPULARITY, #977) — most liked first,
/// ties to the newest — beside Recent's, which `PostDetailViewModel` keeps.
///
/// - **Loaded when the panel mounts,** right after Recent's first page, so
///   its first page is there before the viewer can reach the tab.
/// - **Paged downward;** the ranking is read again per page, so a comment
///   whose likes moved between two pages can come back: it is dropped.
/// - **The viewer's own comments,** sent while the panel is open, lead it
///   as theirs (`addOwn`), the way Instagram shows yours first, without the
///   tab changing.
@MainActor
final class RankedCommentsStream {
    /// The ranked pages, as the server gave them.
    private var ranked: [CommentEntry] = []
    /// The viewer's top-level comments sent here, newest first.
    private var own: [CommentEntry] = []
    private var nextToken: String?
    private var load: Task<Void, Never>?
    private var generation = 0
    /// Whether the first page has answered.
    private(set) var hasAnswered = false
    /// Whether the first page failed with nothing to show.
    private(set) var hasFailed = false
    /// Called when what the stream shows changed.
    var onChange: (() -> Void)?

    /// What the tab shows: the viewer's own first, then the ranking.
    var shown: [CommentEntry] {
        let ownIDs = Set(own.map(\.id))
        return own.flatMap { parent in [parent] + ranked.filter { $0.parentID == parent.id } }
            + ranked.filter { !ownIDs.contains($0.id) && !ownIDs.contains($0.parentID ?? "") }
    }

    /// Whether another page is there to ask for.
    var hasMore: Bool { nextToken != nil }

    /// Forgets everything (the post changed: a draft became a post).
    func reset() {
        generation += 1
        load?.cancel()
        load = nil
        ranked = []
        own = []
        nextToken = nil
        hasAnswered = false
        hasFailed = false
    }

    /// The first ranked page, once.
    func loadFirst(postID: PostID, from provider: any CommentsProviding) {
        guard load == nil, !hasAnswered else { return }
        let asked = generation
        hasFailed = false
        load = Task { [weak self] in
            let page = try? await provider.loadCommentsPage(for: postID, after: nil, order: .popular)
            guard let self, self.generation == asked else { return }
            self.load = nil
            guard let page else {
                self.hasFailed = true
                self.onChange?()
                return
            }
            self.hasAnswered = true
            self.nextToken = page.nextPageToken
            self.ranked = Self.appending(page.entries, to: [])
            self.onChange?()
        }
    }

    /// The next ranked page, when there is one and none is on its way.
    func loadMore(postID: PostID, from provider: any CommentsProviding) {
        guard load == nil, hasAnswered, let token = nextToken else { return }
        let asked = generation
        load = Task { [weak self] in
            let page = try? await provider.loadCommentsPage(for: postID, after: token, order: .popular)
            guard let self, self.generation == asked else { return }
            self.load = nil
            guard let page else { return }
            self.nextToken = page.nextPageToken
            let before = self.ranked.count
            self.ranked = Self.appending(page.entries, to: self.ranked)
            if self.ranked.count != before { self.onChange?() }
        }
    }

    /// The viewer's comment: a top-level one leads the tab; a reply goes
    /// under its parent, wherever that is.
    /// `notify` false for a caller that emits next anyway.
    func addOwn(_ entry: CommentEntry, notify: Bool = true) {
        guard !own.contains(where: { $0.id == entry.id }), !ranked.contains(where: { $0.id == entry.id }) else { return }
        if entry.parentID == nil {
            own.insert(entry, at: 0)
        } else if ranked.contains(where: { $0.id == entry.parentID }) || own.contains(where: { $0.id == entry.parentID }) {
            ranked = PostDetailViewModel.inserting(entry, into: ranked)
        }
        if notify { onChange?() }
    }

    /// One change to every comment held — a review, a delete — in both the
    /// ranking and the viewer's own.
    func update(_ transform: ([CommentEntry]) -> [CommentEntry]) {
        let before = shown
        ranked = transform(ranked)
        own = transform(own)
        if shown != before { onChange?() }
    }

    /// `page` after `list`, without the ids already there: the ranking is
    /// read again per page (comment.v1).
    static func appending(_ page: [CommentEntry], to list: [CommentEntry]) -> [CommentEntry] {
        var known = Set(list.map(\.id))
        return list + page.filter { known.insert($0.id).inserted }
    }
}
