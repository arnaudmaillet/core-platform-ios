import CoreGraphics

/// Which mosaic tiles wear their post's author and the start of its caption
/// over the picture — the Following card's foot (`PostCardCaptionOverlay`) —
/// and how much of the caption. The EXPERIMENT `-gallery-tile-info`
/// (2026-10-03), on For You's chunks and the pushed Discover gallery; off, a
/// tile is the picture and its likes, as on every grid.
///
/// ## The rule: by the tile's size in points, never by its share of the mosaic
///
/// What has to fit is TYPE, and type has an absolute size: a tile a fifth of
/// a big phone's mosaic is the same number of points as a quarter of a small
/// one's, and holds the same words. So the thresholds are points, measured
/// against the Following card — 2.3 across the row, ~160×213pt — which is
/// what wears the full foot today:
///
/// | tile | foot |
/// |---|---|
/// | ≥ `fullMinimumSize` (150×180) | author + 2 caption lines — the Following card's |
/// | ≥ `compactMinimumSize` (130×130) | author + 1 caption line |
/// | smaller | nothing: the picture and its likes, as today |
///
/// - WIDTH keeps the author line honest: a 16pt face, the name, and the heart
///   closing the line. Under ~130pt the name is a few letters before the
///   heart, which reads as a broken label, not as information.
/// - HEIGHT keeps the picture the star: the words may take at most
///   `maximumTextShare` of the tile (`PostCardCaptionOverlay.mediaTextHeight`).
///   At the default text size the minimum sizes are what bind; at a large
///   Dynamic Type size the share does, and a tile steps DOWN a variant —
///   two lines to one, one to none — rather than burying its picture.
///
/// The mosaics' tiles average ~25k pt² (`MosaicChunkPlanner.rowHeightRatio`,
/// the gallery's 14 cells a slice), so roughly the larger half of them carry
/// words and the slivers between stay pictures.
///
/// Text posts never meet this: a chunk and the gallery hold MEDIA only
/// (`MosaicChunkPlanner.isTileEligible`, the gallery's media corpus), and a
/// text post is already its words on the list's card.
public enum PostTileInfo {
    public enum Variant: Equatable, Sendable {
        /// No words: the picture and its likes.
        case none
        /// The author line and ONE caption line.
        case compact
        /// The author line and TWO caption lines — the Following card's foot.
        case full

        /// How many caption lines the variant shows — 0 for `.none`, which
        /// shows no overlay at all.
        public var captionLines: Int {
            switch self {
            case .none: 0
            case .compact: 1
            case .full: PostCardCaptionOverlay.mediaCaptionLines
            }
        }
    }

    /// The smallest tile that wears the Following card's whole foot.
    public static let fullMinimumSize = CGSize(width: 150, height: 180)
    /// The smallest tile that wears the author and one line.
    public static let compactMinimumSize = CGSize(width: 130, height: 130)
    /// The most of a tile's height its words may cover.
    public static let maximumTextShare: CGFloat = 0.5

    /// The variant a tile of `size` wears.
    ///
    /// `textHeight` is how tall the words stand for a number of caption lines
    /// — the overlay's own measure at the current text size, injectable so
    /// the rule can be pinned at any size without Dynamic Type.
    @MainActor
    public static func variant(
        for size: CGSize,
        textHeight: (Int) -> CGFloat = { PostCardCaptionOverlay.mediaTextHeight(captionLines: $0) }
    ) -> Variant {
        for candidate in [Variant.full, .compact] {
            let minimum = candidate == .full ? fullMinimumSize : compactMinimumSize
            guard size.width >= minimum.width, size.height >= minimum.height else { continue }
            if textHeight(candidate.captionLines) <= size.height * maximumTextShare { return candidate }
        }
        return .none
    }
}
