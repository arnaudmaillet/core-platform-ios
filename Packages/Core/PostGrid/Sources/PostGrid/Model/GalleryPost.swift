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

    /// One piece of media in a post, in the order the author arranged them.
    ///
    /// The contract has always been plural — `post.v1.PostView.attachments` is
    /// a repeated field and `PostKind` has a `carousel` case beside `main_video`
    /// — and the client collapsed it with `.first` in four projections. This is
    /// where the collapse stops.
    public struct MediaPage: Equatable, Sendable {
        public let thumbnailURL: URL?
        /// Non-nil only for a playable page — see `GalleryPost.videoURL` for
        /// why this is the same URL the full-screen viewer opens.
        public let videoURL: URL?
        /// This PAGE's own shape. Pages of one post need not agree, which is
        /// why it lives here rather than on the post.
        public let aspectRatio: Double

        public init(thumbnailURL: URL?, videoURL: URL? = nil, aspectRatio: Double = 1) {
            self.thumbnailURL = thumbnailURL
            self.videoURL = videoURL
            self.aspectRatio = aspectRatio
        }
    }

    public let id: PostID
    public let kind: Kind
    /// post.v1 lineage: a non-empty `parent_id` marks the author's post as a
    /// repost of that parent — the grid's Posts/Reposts split.
    public let isRepost: Bool
    /// The post's media, in order. Empty for a text post.
    ///
    /// The TRUTH, with the single-media accessors below derived from it — the
    /// other way round would have meant a second source for the same fact, and
    /// the four projections that used to call `.first` would each have had to
    /// keep the two in step.
    public let pages: [MediaPage]

    /// The first page's thumbnail, which is what every surface that shows ONE
    /// piece of a post shows: a mosaic brick, a map pin, a flight's cover.
    public var thumbnailURL: URL? { pages.first?.thumbnailURL }
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
    public var videoURL: URL? { pages.first?.videoURL }
    /// The FIRST page's pixel aspect ratio (width / height), which is what a
    /// carousel is laid out at: the box takes the shape the viewer sees on
    /// arrival, and later pages aspect-fill it.
    ///
    /// **1.0 is also what "unknown" looks like**, deliberately.
    /// `CoreModels.MediaAttachment.aspectRatio` already returns 1 when the
    /// contract carried no dimensions, so an attachment the backend never
    /// stamped reads as square — and a square tile does not autoplay. The
    /// restriction is therefore fail-closed: where dimensions are missing the
    /// grid shows a still rather than guessing.
    public var aspectRatio: Double { pages.first?.aspectRatio ?? 1 }

    /// Whether this post is a collection — the only question the card's
    /// carousel asks. Reads the PAGES rather than the wire's `carousel` kind,
    /// which the client has never consumed and which the mock sets for any
    /// non-video media post.
    public var isCollection: Bool { pages.count > 1 }

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
        // A text post has no page at all, and the distinction is load-bearing:
        // `pages.first` is what the single-media accessors read, so a synthetic
        // page here would give a text post a thumbnail of nil dressed up as
        // media it does not have.
        //
        // ⚠️ Keyed on the KIND, not on whether a URL arrived. Keying on the URL
        // was tried and it silently dropped the aspect ratio of any media post
        // whose thumbnail failed to parse: no URL meant no page, no page meant
        // `aspectRatio` fell back to 1, and the row drew a square. The kind is
        // what says whether there is media; a URL says whether it can be shown.
        self.pages = kind == .text
            ? []
            : [MediaPage(thumbnailURL: thumbnailURL, videoURL: videoURL, aspectRatio: aspectRatio)]
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

    /// The collection initializer. The single-media one above stays because
    /// most builders genuinely have one piece — a map pin, a repost projection,
    /// a test fixture — and making them all wrap it in an array would be noise.
    public init(
        id: PostID,
        kind: Kind,
        isRepost: Bool,
        pages: [MediaPage],
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
        self.pages = pages
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
