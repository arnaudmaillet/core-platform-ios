import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A mosaic tile large enough wears its post's author and the start of its
/// caption over the picture — the Following card's foot
/// (`PostCardCaptionOverlay`) — and the small ones stay pictures (the
/// `-gallery-tile-info` experiment, validated 3 October 2026: For You's hosts
/// always ask, other grids never do). These pin the size rule, what the
/// overlay says, that a tile not asked for words is exactly the tile it was,
/// and that every copy of a tile
/// (a flight's furniture, a close's stand-in) wears the same words laid out
/// the same way.
@MainActor
struct TileInfoOverlayTests {
    private static let longCaption = String(
        repeating: "A long caption about a sunset over the harbour, with boats and gulls. ", count: 6
    )

    private static func post(
        caption: String = longCaption, name: String? = "Ada Lovelace", handle: String? = "ada"
    ) -> GalleryPost {
        GalleryPost(
            id: PostID("tile-1"), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.com/tile-1.jpg"),
            caption: caption, publishedAtMS: 0,
            authorID: ProfileID("ada"), authorName: name, authorHandle: handle,
            reactionCount: 1_200
        )
    }

    private static let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    /// The Following card's own size, 2.3 across a 402pt row at 3:4.
    private static let large = CGSize(width: 160, height: 213)
    private static let medium = CGSize(width: 140, height: 140)
    private static let small = CGSize(width: 110, height: 150)

    private func tile(
        _ size: CGSize, showsInfo: Bool = true, post: GalleryPost = post()
    ) -> PostGridTileCell {
        let cell = PostGridTileCell(frame: CGRect(origin: .zero, size: size))
        cell.configure(with: post, imagePipeline: Self.pipeline, showsInfo: showsInfo)
        cell.layoutIfNeeded()
        return cell
    }

    // MARK: - The size rule

    /// Big tiles get the Following card's two lines, medium ones one, small
    /// ones none — and each threshold is the named constant, both ways.
    @Test func theRulePicksTheVariantByTheTilesSize() {
        let fixed: (Int) -> CGFloat = { _ in 0 }
        #expect(PostTileInfo.variant(for: Self.large, textHeight: fixed) == .full)
        #expect(PostTileInfo.variant(for: PostTileInfo.fullMinimumSize, textHeight: fixed) == .full)
        #expect(PostTileInfo.variant(for: Self.medium, textHeight: fixed) == .compact)
        #expect(PostTileInfo.variant(for: PostTileInfo.compactMinimumSize, textHeight: fixed) == .compact)
        #expect(PostTileInfo.variant(for: Self.small, textHeight: fixed) == .none)

        let full = PostTileInfo.fullMinimumSize
        let compact = PostTileInfo.compactMinimumSize
        // One point short on either axis steps down.
        #expect(PostTileInfo.variant(for: CGSize(width: full.width - 1, height: 400), textHeight: fixed) == .compact)
        #expect(PostTileInfo.variant(for: CGSize(width: 400, height: full.height - 1), textHeight: fixed) == .compact)
        #expect(PostTileInfo.variant(for: CGSize(width: compact.width - 1, height: 400), textHeight: fixed) == .none)
        #expect(PostTileInfo.variant(for: CGSize(width: 400, height: compact.height - 1), textHeight: fixed) == .none)
        // A full-width letterbox is wide enough but too short to carry words.
        #expect(PostTileInfo.variant(for: CGSize(width: 361, height: 120), textHeight: fixed) == .none)

        #expect(PostTileInfo.Variant.full.captionLines == 2)
        #expect(PostTileInfo.Variant.compact.captionLines == 1)
        #expect(PostTileInfo.Variant.none.captionLines == 0)
    }

    /// The words may cover at most half the tile: type that grows (Dynamic
    /// Type) steps a tile DOWN a variant rather than burying its picture.
    @Test func wordsThatWouldCoverHalfTheTileStepItDown() {
        let size = CGSize(width: 200, height: 200)
        // Two lines too tall, one fits: compact.
        #expect(PostTileInfo.variant(for: size) { $0 >= 2 ? 101 : 100 } == .compact)
        // Neither fits: none.
        #expect(PostTileInfo.variant(for: size) { _ in 101 } == .none)
        // And at the default text size the minimum sizes are what bind: the
        // full foot fits the smallest full tile with room to spare.
        let measured = PostCardCaptionOverlay.mediaTextHeight(captionLines: 2)
        #expect(measured <= PostTileInfo.fullMinimumSize.height * PostTileInfo.maximumTextShare)
        #expect(PostTileInfo.variant(for: PostTileInfo.fullMinimumSize) == .full)
        #expect(PostTileInfo.variant(for: PostTileInfo.compactMinimumSize) == .compact)
    }

    // MARK: - Flag off

    /// A tile nobody asked for words is the tile it always was: no overlay,
    /// its likes in the corner — at any size.
    @Test func aTileNotAskedForWordsIsUnchanged() {
        for size in [Self.large, Self.medium, Self.small] {
            let cell = tile(size, showsInfo: false)
            #expect(cell.debugInfoOverlay == nil)
            #expect(cell.infoVariant == .none)
            #expect(cell.debugShowsCornerLikes)
            #expect(cell.debugCounterText == "1.2K")
            #expect(cell.contentView.subviews.contains { $0 is PostCardCaptionOverlay } == false)
        }
    }

    // MARK: - Flag on

    /// A large tile wears the full foot, its likes moved from the corner to
    /// the end of the author line; a medium one a single line; a small one
    /// stays a picture with its corner count.
    @Test func eachTileWearsTheVariantItsSizeEarns() throws {
        let large = tile(Self.large)
        let overlay = try #require(large.debugInfoOverlay)
        #expect(large.infoVariant == .full)
        #expect(overlay.debugCaptionLineLimit == 2)
        #expect(large.debugShowsCornerLikes == false, "one heart, not two")
        #expect(large.debugCounterText == "1.2K", "the likes moved, they did not vanish")
        // The heart closes the AUTHOR line, on the tile's 10pt inset.
        let heart = overlay.debugLikeFrame
        #expect(heart.isNull == false)
        #expect(abs(heart.midY - overlay.debugAuthorFrame.midY) < 0.5, "\(heart) vs \(overlay.debugAuthorFrame)")
        #expect(abs(heart.maxX - (Self.large.width - 10)) < 0.5, "\(heart)")
        #expect(overlay.debugAuthorFrame.maxX <= heart.minX)
        #expect(overlay.likeReadout?.isUserInteractionEnabled == false, "a readout, never a control")

        let medium = tile(Self.medium)
        #expect(medium.infoVariant == .compact)
        #expect(try #require(medium.debugInfoOverlay).debugCaptionLineLimit == 1)
        #expect(medium.debugShowsCornerLikes == false)

        let small = tile(Self.small)
        #expect(small.infoVariant == .none)
        #expect(small.debugInfoOverlay == nil)
        #expect(small.debugShowsCornerLikes)
    }

    /// What the words say: the author's name (the handle when there is no
    /// name), and the caption cut to the variant's lines, at the foot.
    @Test func theOverlaySaysWhoAndTheStartOfWhat() throws {
        let large = tile(Self.large)
        let overlay = try #require(large.debugInfoOverlay)
        #expect(overlay.debugAuthorText == "Ada Lovelace")
        #expect(overlay.debugCaptionText == Self.longCaption)
        #expect(overlay.debugCaptionRenderedLines == 2, "a long caption is TRUNCATED to two lines")
        // Anchored at the foot, on the inset; the author just above it.
        #expect(abs(overlay.debugCaptionFrame.maxY - (Self.large.height - 10)) < 0.5)
        #expect(overlay.debugAuthorFrame.maxY <= overlay.debugCaptionFrame.minY)
        #expect(overlay.debugAvatarFrame.isNull == false, "the author's face leads the name")

        let medium = try #require(tile(Self.medium).debugInfoOverlay)
        #expect(medium.debugCaptionRenderedLines == 1)

        let handleOnly = try #require(tile(Self.large, post: Self.post(name: nil)).debugInfoOverlay)
        #expect(handleOnly.debugAuthorText == "@ada")

        // No caption: the author alone, still at the foot.
        let bare = try #require(tile(Self.large, post: Self.post(caption: "")).debugInfoOverlay)
        #expect(bare.debugCaptionRenderedLines == 0)
        #expect(bare.debugAuthorFrame.maxY > Self.large.height - 20)
    }

    /// A screen of tiles is a dozen overlays at once: their words carry their
    /// shadow INSIDE the glyphs, never on a layer (an offscreen pass apiece).
    /// The Following card keeps its layer shadow, as it was.
    @Test func aTilesWordsCostNoOffscreenPass() throws {
        let overlay = try #require(tile(Self.large).debugInfoOverlay)
        #expect(overlay.debugUsesLayerShadows == false)
        let following = PostCardCaptionOverlay(post: Self.post(), placement: .onMedia)
        #expect(following.debugUsesLayerShadows)
    }

    /// A recycled tile drops its words; reconfigured without them it is a
    /// plain tile again.
    @Test func reuseDropsTheWords() {
        let cell = tile(Self.large)
        #expect(cell.debugInfoOverlay != nil)
        cell.prepareForReuse()
        #expect(cell.debugInfoOverlay == nil)
        cell.configure(with: Self.post(), imagePipeline: Self.pipeline)
        cell.layoutIfNeeded()
        #expect(cell.debugInfoOverlay == nil)
        #expect(cell.debugShowsCornerLikes)
    }

    /// A cell configured before the collection view sized it decides at its
    /// first layout — and changes variant only when its size crosses a
    /// threshold.
    @Test func theVariantFollowsTheCellsSize() throws {
        let cell = PostGridTileCell(frame: .zero)
        cell.configure(with: Self.post(), imagePipeline: Self.pipeline, showsInfo: true)
        #expect(cell.debugInfoOverlay == nil, "no size, no words yet")
        cell.frame = CGRect(origin: .zero, size: Self.large)
        cell.layoutIfNeeded()
        let first = try #require(cell.debugInfoOverlay)
        cell.frame = CGRect(origin: .zero, size: CGSize(width: 170, height: 230))
        cell.layoutIfNeeded()
        #expect(cell.debugInfoOverlay === first, "same variant: the same overlay, not rebuilt")
        cell.frame = CGRect(origin: .zero, size: Self.small)
        cell.layoutIfNeeded()
        #expect(cell.debugInfoOverlay == nil)
        #expect(cell.debugShowsCornerLikes)
    }

    /// The heart is red once the viewer has staked, as the corner's was.
    @Test func theHeartTurnsRedWithTheViewersStake() throws {
        let cell = tile(Self.large)
        #expect(try #require(cell.debugInfoOverlay?.likeReadout).debugIsStaked == false)
        cell.setViewerStake(3)
        #expect(try #require(cell.debugInfoOverlay?.likeReadout).debugIsStaked)
        // A variant built after the stake reads it too.
        cell.frame = CGRect(origin: .zero, size: Self.medium)
        cell.layoutIfNeeded()
        #expect(try #require(cell.debugInfoOverlay?.likeReadout).debugIsStaked)
    }

    // MARK: - Copies: the flight's furniture and the close's stand-in

    /// The flight's copy is the tile's own words at the tile's size — the
    /// same frames — and nil where the tile wears none.
    @Test func theFlightsCopyIsTheTilesOwnWords() throws {
        let cell = tile(Self.large)
        let own = try #require(cell.debugInfoOverlay)
        let copy = try #require(PostGridTileCell.makeInfoOverlay(
            for: Self.post(), restingSize: Self.large, imagePipeline: Self.pipeline
        ))
        #expect(copy.debugCaptionFrame == own.debugCaptionFrame)
        #expect(copy.debugAuthorFrame == own.debugAuthorFrame)
        #expect(copy.debugLikeFrame == own.debugLikeFrame)
        #expect(copy.debugCaptionLineLimit == own.debugCaptionLineLimit)
        #expect(PostGridTileCell.makeInfoOverlay(
            for: Self.post(), restingSize: Self.small, imagePipeline: Self.pipeline
        ) == nil)
    }

    /// The copy rides a window: at any size it keeps the words wrapped at the
    /// tile's width and pinned to the foot, scaled — never re-wrapped.
    @Test func theFlightsCopyIsPosedNotRelaidOut() throws {
        let copy = try #require(PostGridTileCell.makeInfoOverlay(
            for: Self.post(), restingSize: Self.large, imagePipeline: Self.pipeline
        ))
        let wrap = copy.debugCaptionWrapWidth
        let page = CGSize(width: 402, height: 874)
        copy.frame = CGRect(origin: .zero, size: page)
        copy.layoutIfNeeded()
        let scale = page.width / Self.large.width
        #expect(copy.debugCaptionWrapWidth == wrap)
        #expect(abs(copy.debugCaptionFrame.maxY - (page.height - 10 * scale)) < 0.5)
    }

    /// The close's stand-in lands wearing the slot's words — decided at the
    /// LANDING size, so a window still far larger (or smaller) than the tile
    /// never swaps variant mid-close, and the words keep their wrap.
    @Test func theStandInWearsTheLandingTilesWords() throws {
        let standIn = PostGridTileStandInView(
            post: Self.post(), size: Self.large, imagePipeline: Self.pipeline, showsInfo: true
        )
        let tile = try #require(standIn.subviews.first as? PostGridTileCell)
        let overlay = try #require(tile.debugInfoOverlay)
        #expect(tile.infoVariant == .full)
        #expect(overlay.debugCaptionFrame.width > 0, "laid out before the window ever moves it")
        let wrap = overlay.debugCaptionWrapWidth

        for size in [CGSize(width: 402, height: 874), CGSize(width: 60, height: 60)] {
            standIn.frame = CGRect(origin: .zero, size: size)
            standIn.layoutIfNeeded()
            #expect(tile.debugInfoOverlay === overlay, "the variant never changes with the window")
            #expect(overlay.debugCaptionWrapWidth == wrap)
            let scale = size.width / Self.large.width
            #expect(abs(overlay.debugCaptionFrame.maxY - (size.height - 10 * scale)) < 0.5)
        }

        // Back at the landing size, the stand-in IS the tile.
        standIn.frame = CGRect(origin: .zero, size: Self.large)
        standIn.layoutIfNeeded()
        let cell = self.tile(Self.large)
        let own = try #require(cell.debugInfoOverlay)
        #expect(overlay.debugCaptionFrame == own.debugCaptionFrame)
        #expect(overlay.debugAuthorFrame == own.debugAuthorFrame)

        // Without the flag the stand-in is the plain tile it always was.
        let plain = PostGridTileStandInView(post: Self.post(), size: Self.large, imagePipeline: Self.pipeline)
        let plainTile = try #require(plain.subviews.first as? PostGridTileCell)
        #expect(plainTile.debugInfoOverlay == nil)
        #expect(plainTile.debugShowsCornerLikes)
    }
}
