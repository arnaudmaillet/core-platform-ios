import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A tile decodes its cover at its drawn size (#1505, as #1086 did for
/// avatars): a grid tile is a 512 px decode, not 1200 px.
@MainActor
struct TileCoverDecodeSizeTests {
    private func solid() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func post(_ id: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.com/\(id).jpg"),
            caption: "", publishedAtMS: 0, authorID: ProfileID("ada"),
            authorName: "Ada", authorHandle: "ada", reactionCount: 0
        )
    }

    /// The bucket follows the drawn size: a third of a phone's width is
    /// 512 px (with the slack a 3:4 tile needs), a slice's lead tile and a
    /// tile not laid out yet keep the full picture, and nothing goes below
    /// 256 px — the avatars' namespace.
    @Test func theBucketFollowsTheDrawnSize() {
        #expect(PostGridTileCell.coverBucket(forDrawnSize: CGSize(width: 132, height: 176), scale: 3) == .px512)
        #expect(PostGridTileCell.coverBucket(forDrawnSize: CGSize(width: 145, height: 193), scale: 3) == .px512)
        #expect(PostGridTileCell.coverBucket(forDrawnSize: CGSize(width: 264, height: 352), scale: 3) == .full)
        #expect(PostGridTileCell.coverBucket(forDrawnSize: .zero, scale: 3) == .full)
        #expect(PostGridTileCell.coverBucket(forDrawnSize: CGSize(width: 40, height: 40), scale: 3) == .px256)
    }

    /// A grid tile finds its cover in memory at ITS bucket (what the lookahead
    /// prefetched) and draws it in the configure pass — and a full decode
    /// already in memory serves it too (the pipeline answers a smaller ask
    /// from a larger decode).

    @Test func aGridTileReadsItsOwnBucket() {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let tilePost = post("small")
        pipeline.store(solid(), for: tilePost.thumbnailURL!, size: .px512)
        let tile = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 132, height: 176))
        tile.configure(with: tilePost, imagePipeline: pipeline)
        #expect(tile.renderedCover != nil, "the tile asked for another bucket than its own")

        let fullOnly = post("full-only")
        pipeline.store(solid(), for: fullOnly.thumbnailURL!, size: .full)
        let other = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 132, height: 176))
        other.configure(with: fullOnly, imagePipeline: pipeline)
        #expect(other.renderedCover != nil, "a full decode in memory did not serve the tile")
    }
}
