import CoreModels
import Foundation

/// One post as every screen sees it: its content and its counters, the same
/// for every viewer. What the VIEWER did to it (saved it, staked on it) is not
/// here: those facts are wiped on a viewer change, the content is not
/// (`EntityStore`).
public struct PostEntity: Sendable, Equatable {
    public let id: PostID
    /// Nil while only the counters are known: a grid's tile or a realtime
    /// tick can name a post no screen has hydrated yet.
    public var post: Post?
    /// The post's like count: the server's, plus the points staked on it from
    /// this device since (`EntityStore.addLikes`).
    public var likeCount: Int64?
    public var commentCount: Int64?

    public init(id: PostID, post: Post? = nil, likeCount: Int64? = nil, commentCount: Int64? = nil) {
        self.id = id
        self.post = post
        self.likeCount = likeCount
        self.commentCount = commentCount
    }

    /// The count to draw, or nil when the author hides it from this reader
    /// (#397): a hidden count is no number at all, never a 0.
    public var visibleLikeCount: Int64? {
        post?.likeCountsHidden == true ? nil : likeCount
    }
}

/// One person as every screen sees it. Where the VIEWER stands with them is
/// not here (`EntityStore.relation(to:)`).
public struct ProfileEntity: Sendable, Equatable {
    public let id: ProfileID
    public var summary: AuthorSummary?

    public init(id: ProfileID, summary: AuthorSummary? = nil) {
        self.id = id
        self.summary = summary
    }
}

/// The counters a list read for one post.
public struct PostCounts: Sendable, Equatable {
    public var likes: Int64?
    public var comments: Int64?

    public init(likes: Int64? = nil, comments: Int64? = nil) {
        self.likes = likes
        self.comments = comments
    }
}

/// How much a write's counters are worth against what the store holds.
public enum CountFreshness: Sendable {
    /// Read from the server just now: replaces what the store holds.
    case fresh
    /// From a copy that may be older than the store's (a page restored from
    /// the device, a projection a screen built earlier): fills a counter the
    /// store does not know, never replaces one it does.
    case ifUnknown
}

/// Which entities a write changed, for an observer of a whole kind.
public enum EntityChange<ID: Hashable & Sendable>: Sendable, Equatable {
    case some(Set<ID>)
    /// Every entity of the kind may have changed: a viewer change wiped the
    /// viewer's facts.
    case everything

    public func contains(_ id: ID) -> Bool {
        switch self {
        case .some(let ids): ids.contains(id)
        case .everything: true
        }
    }
}

/// Keeps an `EntityStore` observer registered for as long as it lives:
/// release it, or `cancel()`, and the handler is gone — and the entity it
/// pinned goes back to its tier.
public final class EntityObservation: Sendable {
    private let onCancel: @Sendable () -> Void
    private let cancelled = Flag()

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        guard cancelled.set() else { return }
        onCancel()
    }

    deinit { cancel() }
}
