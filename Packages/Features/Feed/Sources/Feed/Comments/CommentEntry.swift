import CoreModels
import Foundation

// One comment, as a value (#2379, stage A1): out of `CommentsRepository` so
// the post surfaces can read it without the comments' data layer.

/// One top-level comment, hydrated with its author's display name (the
/// comment.v1 view carries only ids).
public struct CommentEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let authorID: ProfileID
    public let authorName: String
    public let authorHandle: String
    /// The author's avatar, hydrated from profile.v1 alongside the name/handle.
    /// Optional — an unresolved author (or one with no avatar) carries nil.
    public let authorAvatarURL: URL?
    /// The author's avatar frame (#943), hydrated with the avatar; nil for
    /// none.
    public let authorAvatarFrameID: String?
    /// The comment's words. Empty when an attachment speaks for it: a voice
    /// alone is a valid comment (#2309).
    public let body: String
    /// What the comment carries besides its words (#2309): a voice for now,
    /// a kind this build doesn't know as `.unsupported`. Nil for a plain
    /// text comment. The row draws it in its slot (`CommentRowView`); a
    /// one-line surface reads `oneLineText`.
    public let attachment: CommentAttachment?
    public let createdAt: Date
    /// The parent comment's id when this entry is a level-2 reply
    /// (comment.v1 carries exactly two levels: top-level and replies).
    /// Nil for top-level comments.
    public let parentID: String?
    /// Held for the post owner's review (their temporary interaction limit,
    /// #416): only its author and the post's owner see it until it is
    /// approved.
    public let isHeld: Bool
    /// A top-level comment's replies on the server, held ones included
    /// (comment.v1 `reply_count`, #637) — what "View N more replies" counts
    /// from, since only the most popular two are loaded with the page. Nil
    /// for a reply, and wherever the count is not known (a record from an
    /// older build).
    public var replyCount: Int?

    public init(
        id: String,
        authorID: ProfileID,
        authorName: String,
        authorHandle: String,
        authorAvatarURL: URL? = nil,
        authorAvatarFrameID: String? = nil,
        body: String,
        attachment: CommentAttachment? = nil,
        createdAt: Date,
        parentID: String? = nil,
        isHeld: Bool = false,
        replyCount: Int? = nil
    ) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.authorAvatarFrameID = authorAvatarFrameID
        self.body = body
        self.attachment = attachment
        self.createdAt = createdAt
        self.parentID = parentID
        self.isHeld = isHeld
        self.replyCount = replyCount
    }

    /// The comment as one line of words (#2309): its text, or "🎙 12″" for
    /// a voice alone, or a neutral line for a kind this build can't draw —
    /// what the band, the danmaku and the subtitle zone show.
    public var oneLineText: String { CommentAttachment.oneLineText(body: body, attachment: attachment) }

    /// This comment once its post's owner approved it: shown to everyone.
    func released() -> CommentEntry {
        CommentEntry(
            id: id, authorID: authorID, authorName: authorName, authorHandle: authorHandle,
            authorAvatarURL: authorAvatarURL, authorAvatarFrameID: authorAvatarFrameID, body: body,
            attachment: attachment, createdAt: createdAt, parentID: parentID, replyCount: replyCount
        )
    }
}
