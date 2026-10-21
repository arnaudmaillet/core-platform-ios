import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A tile's count, round 2 of the side list (#1509): a narrow tile takes the
/// compact register on its own, and every tile's count sits over a low, light
/// gradient.
@MainActor
struct TileCompactCounterTests {
    private static let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    private static func post(likes: Int64 = 812) -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.test/p.jpg"),
            caption: "", publishedAtMS: 0, reactionCount: likes
        )
    }

    private func tile(width: CGFloat) -> PostGridTileCell {
        let cell = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: width, height: (width * 4 / 3).rounded()))
        cell.configure(with: Self.post(), imagePipeline: Self.pipeline, showsInfo: false)
        cell.layoutIfNeeded()
        return cell
    }

    /// ⚠️ BELOW THE THRESHOLD, THE COMPACT REGISTER (#1509): the side list's
    /// tiles (about 70 pt) take it; the grids' keep their size. The count is
    /// whole either way.
    @Test func aNarrowTileTakesTheCompactCounter() {
        let narrow = tile(width: 70)
        #expect(narrow.isCompact)
        #expect(narrow.debugCounterText == "812")
        let wide = tile(width: PostGridTileCell.compactWidth + 30)
        #expect(!wide.isCompact, "a grid tile shrank its count")
        // The threshold itself is regular.
        #expect(!tile(width: PostGridTileCell.compactWidth).isCompact)
    }

    /// The compact count fits a narrow tile whole: its frame stays inside
    /// the tile, never clipped at the leading edge.
    @Test func theCompactCountFitsWhole() throws {
        let narrow = tile(width: 66)
        let label = try #require(narrow.contentView.subviews.first { $0 is PostMetricLabel })
        #expect(label.frame.minX >= 0 && label.frame.maxX <= narrow.bounds.width, "the count runs off the tile: \(label.frame)")
        #expect(label.intrinsicContentSize.width <= label.frame.width + 0.5, "the count is truncated")
    }

    /// ⚠️ A GRADIENT BEHIND THE COUNT ON EVERY TILE (#1509), low and light,
    /// along the bottom edge; none when the count is not drawn.
    @Test func everyTileWearsTheGradientBehindItsCount() {
        for width in [CGFloat(70), 160] {
            let cell = tile(width: width)
            #expect(cell.debugShowsCountGradient, "no gradient at \(width) pt")
        }
        let frame = PostTileCountGradientView.frame(in: CGRect(x: 0, y: 0, width: 160, height: 213))
        #expect(frame.maxY == 213 && frame.height <= PostGridTileCell.countGradientMaxHeight)
        #expect(PostGridTileCell.countGradientOpacity <= 0.4, "the gradient is not light")
    }
}
