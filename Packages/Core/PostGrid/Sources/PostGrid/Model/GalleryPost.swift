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
    /// The playable stream for a `.video` post — an HLS manifest where the
    /// backend serves one, else the progressive asset. `nil` for stills, and
    /// for videos the service didn't vend a URL for.
    ///
    /// Deliberately the **same** URL the full-screen viewer opens, not a
    /// lightweight preview. A tile and its full-screen destination must share
    /// one `AVPlayerItem` for the hero zoom to keep the playhead, so quality is
    /// moved with `preferredPeakBitRate` on that item rather than by swapping
    /// assets. See `dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §0.3 — this
    /// is why the grid does not use `preview_url` while the map does.
    public let videoURL: URL?
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
        videoURL: URL? = nil,
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
        self.videoURL = videoURL
        self.caption = caption
        self.publishedAtMS = publishedAtMS
        self.reactionCount = reactionCount
        self.commentCount = commentCount
        self.viewCount = viewCount
    }
}
