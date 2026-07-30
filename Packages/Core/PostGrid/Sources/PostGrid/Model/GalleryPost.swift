import CoreModels
import Foundation

/// One tile of a post grid, hydrated from post.v1.
///
/// Shared by every surface that renders posts as a mosaic or a timeline list —
/// the profile's gallery and the For You discovery tab — so a tile means the
/// same thing wherever it appears. Hydration stays with each feature's
/// repository; this is only what the cells read.
public struct GalleryPost: Equatable, Sendable {
    /// What the post *is* — the grid's content-type filter axis. Derived from
    /// the post kind when the service provides one, else from the first
    /// attachment's MIME type (the same routing rule the snap feed uses).
    public enum Kind: Equatable, Sendable, CaseIterable {
        case photo
        case video
        case text
    }

    public let id: PostID
    public let kind: Kind
    /// post.v1 lineage: a non-empty `parent_id` marks the author's post as a
    /// repost of that parent — the grid's Posts/Reposts split.
    public let isRepost: Bool
    public let thumbnailURL: URL?
    public let caption: String
    public let publishedAtMS: Int64
    /// counter.v1 projections; nil when the read-model had no value (the
    /// cells hide the counter rather than asserting a zero).
    public var reactionCount: Int64?
    public var commentCount: Int64?
    public var viewCount: Int64?

    public init(
        id: PostID,
        kind: Kind,
        isRepost: Bool,
        thumbnailURL: URL?,
        caption: String,
        publishedAtMS: Int64,
        reactionCount: Int64? = nil,
        commentCount: Int64? = nil,
        viewCount: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.isRepost = isRepost
        self.thumbnailURL = thumbnailURL
        self.caption = caption
        self.publishedAtMS = publishedAtMS
        self.reactionCount = reactionCount
        self.commentCount = commentCount
        self.viewCount = viewCount
    }
}
