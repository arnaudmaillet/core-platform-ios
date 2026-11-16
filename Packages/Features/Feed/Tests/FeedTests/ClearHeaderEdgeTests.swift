import MediaCore
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces

/// Every For You surface under the header hides the system's top edge effect.
///
/// ⚠️ Left alone, the effect is a progressive blur on iOS 26.5 and a flat band
/// with a hard cutoff and a hairline on iOS 27; the app wants neither — the
/// header is bare and nothing is drawn under it. A
/// missing call brings the system's effect back and fails to compile nowhere,
/// which is why each one is pinned. See `prefersClearTopEdge`.
@MainActor
struct ClearHeaderEdgeTests {
    private func pipeline() -> ImagePipeline { ImagePipeline(fetcher: PlaceholderImageFetcher()) }

    @Test(arguments: [PostGridPageView.Style.grid, .list, .discover])
    func aForYouPageHidesTheEffectUnderTheHeader(style: PostGridPageView.Style) throws {
        let page = PostGridPageView(imagePipeline: pipeline(), style: style)
        let list = try #require(page.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(list.topEdgeEffect.isHidden)
    }

    /// ⚠️ AND THE ROWS' OWN SCROLLERS. For You's list is led by horizontal
    /// rows (`ShelfLeadFixture`: its shelf's media and text rows); a row is a scroll view under the same header, and its effect
    /// would draw a band across the header too.
    @Test func theForYouRowsHideTheirEffectToo() throws {
        let lead = ShelfLeadFixture(pipeline: pipeline(), videoPlayback: nil)
        let rows = lead.shelf.subviews.compactMap { $0 as? UIScrollView }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.topEdgeEffect.isHidden })
    }
}
