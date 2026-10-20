import CoreModels
import DesignSystem
import Foundation

/// View-ready projection of a `CommentEntry`.
public struct CommentDisplayModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let authorID: ProfileID
    public let authorName: String
    /// The relative time alone — the header shows ONLY the clean display
    /// name beside it (the @handle identifier was removed for reading
    /// comfort; the handle still travels on `CommentEntry` for routing
    /// stubs).
    public let metaText: String
    public let body: String
    /// The two-letter initials — the row's RENDERED identity, drawn
    /// immediately and permanently. The picture (if any) is layered over
    /// it; it is never swapped for it, so there is no empty disc at any
    /// point and no third "loading" state.
    public let monogram: String
    /// The author's picture, hydrated onto `CommentEntry` from profile.v1.
    /// Optional at every step: an unresolved author, an author with no
    /// avatar, and a failed fetch are all the same outcome — the monogram
    /// stands.
    public let avatarURL: URL?
    /// The author's avatar frame (#943); nil for none.
    public var avatarFrameID: String?
    /// The thread parent's id for level-2 replies; nil at top level.
    public let parentID: String?
    /// When it was written — what the day pills group by. Nil for a row built
    /// without one.
    public let createdAt: Date?
    /// Level-2 marker: replies render with the standard reply indentation
    /// (the stream carries exactly two depths — comment.v1's contract).
    public var isReply: Bool { parentID != nil }
    /// Held for the post owner's review (#416): seen only by its author and
    /// the owner, and marked so on the row.
    public let isHeld: Bool
    /// The viewer owns the post and may approve or decline this held comment.
    public let canReview: Bool
    /// A thread the viewer started (#921): it rides in the viewer's own
    /// section, right under the caption, whatever the sort.
    public let isOwnThread: Bool
    /// A top-level comment's replies on the server (#637): "View N more
    /// replies" counts from it. Nil when not known.
    public var replyCount: Int?
    /// Everyone's likes on it — points staked (#637); 0 when not known.
    public var likeCount: Int = 0
    /// The viewer has a point on it.
    public var isLiked = false

    public init(
        entry: CommentEntry, now: Date = Date(), canReview: Bool = false, isOwnThread: Bool = false,
        likes: CommentLikes? = nil
    ) {
        id = entry.id
        authorID = entry.authorID
        authorName = entry.authorName
        body = entry.body
        parentID = entry.parentID
        monogram = MonogramAvatarView.monogram(name: entry.authorName, handle: "")
        avatarURL = entry.authorAvatarURL
        avatarFrameID = entry.authorAvatarFrameID
        metaText = RelativeAgeFormatter.short(from: entry.createdAt, to: now)
        createdAt = entry.createdAt
        isHeld = entry.isHeld
        self.canReview = entry.isHeld && canReview
        self.isOwnThread = isOwnThread
        replyCount = entry.replyCount
        likeCount = Int(clamping: likes?.count ?? 0)
        isLiked = (likes?.mine ?? 0) > 0
    }

    /// A row that is not a comment: a conversation's message, drawn in the
    /// comment grammar. `metaText` is whatever the header
    /// shows beside the name — a clock time there, under the day pills.
    init(
        id: String,
        authorID: ProfileID,
        authorName: String,
        metaText: String,
        body: String,
        avatarURL: URL?,
        parentID: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.metaText = metaText
        self.body = body
        self.avatarURL = avatarURL
        self.parentID = parentID
        self.createdAt = createdAt
        isHeld = false
        canReview = false
        isOwnThread = false
        monogram = MonogramAvatarView.monogram(name: authorName, handle: "")
    }
}
