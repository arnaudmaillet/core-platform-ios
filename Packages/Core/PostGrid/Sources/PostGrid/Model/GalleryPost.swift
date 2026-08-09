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

    /// The media's own shape, which decides whether a video tile autoplays.
    public enum Shape: Equatable, Sendable {
        case portrait
        case square
        case landscape
    }

    /// How far either side of 1:1 still counts as square.
    ///
    /// ±12% admits the ratios a "square" crop realistically arrives as (1080x1080
    /// exactly, but also 1080x1000 or 960x1040 after a re-encode) without
    /// reaching 4:5 (0.8) or 5:4 (1.25), which are portrait and landscape crops
    /// that should play.
    static let squareToleranceFraction = 0.12

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
    /// The media's pixel aspect ratio (width / height).
    ///
    /// **1.0 is also what "unknown" looks like**, deliberately.
    /// `CoreModels.MediaAttachment.aspectRatio` already returns 1 when the
    /// contract carried no dimensions, so an attachment the backend never
    /// stamped reads as square — and a square tile does not autoplay. The
    /// restriction is therefore fail-closed: where dimensions are missing the
    /// grid shows a still rather than guessing. That is the safe direction for
    /// a rule phrased as a restriction, but it does mean autoplay stays dark on
    /// any surface whose payload omits width/height. See
    /// `BACKEND_MEDIA_ASPECT_RATIO_SUPPORT.md` — this is that gap with teeth.
    public let aspectRatio: Double
    public let caption: String
    public let publishedAtMS: Int64
    /// counter.v1 projections; nil when the read-model had no value (the
    /// cells hide the counter rather than asserting a zero).
    /// The post's author, when the projection that built this carried it.
    ///
    /// The grid itself renders none of this — a tile is media and counters. It
    /// is here because the grid's projection is what a full-screen open is
    /// SEEDED from: without author identity the opened page shows a caption and
    /// a blank author capsule for as long as its own fetch takes (~0.69s
    /// measured), and the capsule then fills in late. Carrying it makes the
    /// open complete at 0ms rather than partial.
    ///
    /// Optional because not every builder has it: the profile gallery is
    /// already scoped to one author and never needed it.
    public var authorID: ProfileID?
    public var authorName: String?
    public var authorHandle: String?
    public var authorAvatarURL: URL?
    public var reactionCount: Int64?
    public var commentCount: Int64?
    public var viewCount: Int64?

    public init(
        id: PostID,
        kind: Kind,
        isRepost: Bool,
        thumbnailURL: URL?,
        videoURL: URL? = nil,
        aspectRatio: Double = 1,
        caption: String,
        publishedAtMS: Int64,
        authorID: ProfileID? = nil,
        authorName: String? = nil,
        authorHandle: String? = nil,
        authorAvatarURL: URL? = nil,
        reactionCount: Int64? = nil,
        commentCount: Int64? = nil,
        viewCount: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.isRepost = isRepost
        self.thumbnailURL = thumbnailURL
        self.videoURL = videoURL
        self.aspectRatio = aspectRatio
        self.caption = caption
        self.publishedAtMS = publishedAtMS
        self.authorID = authorID
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.reactionCount = reactionCount
        self.commentCount = commentCount
        self.viewCount = viewCount
    }

    /// Portrait, square, or landscape, from the media's own pixels.
    public var shape: Shape {
        guard aspectRatio > 0 else { return .square }
        let tolerance = Self.squareToleranceFraction
        if aspectRatio < 1 - tolerance { return .portrait }
        if aspectRatio > 1 + tolerance { return .landscape }
        return .square
    }

    /// Whether this tile may autoplay in a grid.
    ///
    /// Video with a stream, and **not square**. Square tiles stay still
    /// deliberately: they are the mosaic's filler shape, they appear in the
    /// densest runs, and a wall of small moving squares is noise rather than
    /// content. Portrait and landscape bricks are the ones large enough for
    /// motion to read as something.
    public var autoplaysInGrid: Bool {
        hasPlayableVideo && shape != .square
    }

    /// Whether there is a video here to play at all, shape aside.
    ///
    /// What a TIMELINE ROW autoplays on. The square exclusion above is a mosaic
    /// judgement — it is about small filler bricks in a dense wall — and a row's
    /// preview is one fixed landscape box that aspect-fills whatever it is
    /// handed. A square source is no different there to any other, so applying
    /// the grid's rule would leave those rows permanently still for a reason
    /// that never applied to them.
    public var hasPlayableVideo: Bool {
        kind == .video && videoURL != nil
    }
}
