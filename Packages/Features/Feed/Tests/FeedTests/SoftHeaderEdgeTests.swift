import MediaCore
import Testing
import UIKit
@testable import Feed

/// For You's pages, and the pager over them, ask for the SOFT top edge.
///
/// ⚠️ Measured on iOS 27 (iPhone 18 Pro): left `.automatic`, the header over the
/// grid is a flat band with a hard cutoff and a hairline under the bar, where
/// iOS 26.5 draws a progressive blur. A missing call brings the band back on
/// iOS 27 only — iOS 26's `.automatic` is already soft — and fails to compile
/// nowhere, which is why each one is pinned. See `prefersSoftTopEdge`.
@MainActor
struct SoftHeaderEdgeTests {
    private func pipeline() -> ImagePipeline { ImagePipeline(fetcher: PlaceholderImageFetcher()) }

    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func aForYouPageFadesUnderTheHeader(style: ForYouGridPage.Style) throws {
        let page = ForYouGridPage(imagePipeline: pipeline(), style: style)
        let list = try #require(page.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(list.topEdgeEffect.style == .soft)
    }

    /// ⚠️ THE PAGER TOO. Its scroll view spans the header and draws its own
    /// effect: with only the pages soft, iOS 27 still cut the header off at a
    /// hard line.
    @Test func theForYouPagerFadesUnderTheHeaderToo() throws {
        let pager = ForYouPagerView(imagePipeline: pipeline())
        let paging = try #require(pager.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(paging.topEdgeEffect.style == .soft)
    }
}
