import MediaCore
import Testing
import UIKit
@testable import Feed

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

    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func aForYouPageHidesTheEffectUnderTheHeader(style: ForYouGridPage.Style) throws {
        let page = ForYouGridPage(imagePipeline: pipeline(), style: style)
        let list = try #require(page.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(list.topEdgeEffect.isHidden)
    }

    /// ⚠️ THE PAGER TOO. Its scroll view spans the header and draws its own
    /// effect: with only the pages hidden, the pager's band still cut the header
    /// off (measured while the style was the thing being set).
    @Test func theForYouPagerHidesItsEffectToo() throws {
        let pager = ForYouPagerView(imagePipeline: pipeline())
        let paging = try #require(pager.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(paging.topEdgeEffect.isHidden)
    }
}
