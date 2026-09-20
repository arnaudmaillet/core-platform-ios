import MediaCore
import Testing
import UIKit
@testable import Profile

/// The profile's gallery pages, and the pager over them, ask for the SOFT top
/// edge — the header floats over them and fades into them.
///
/// ⚠️ Left `.automatic`, iOS 27 can draw a hard band with a hairline under a
/// header where iOS 26.5 draws a progressive blur (measured on the inbox, For
/// You and the relationship lists). A missing call shows on iOS 27 only and
/// fails to compile nowhere, so each one is pinned. See `prefersSoftTopEdge`.
@MainActor
struct ProfileSoftHeaderEdgeTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    @Test func aGalleryPageFadesUnderTheHeader() throws {
        let page = ProfileGalleryGridView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid, tab: .format(.activity)
        )
        let list = try #require(page.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(list.topEdgeEffect.style == .soft)
    }

    /// ⚠️ THE PAGER TOO: its scroll view spans the header and draws its own
    /// effect, so pages alone leave the hard line in place.
    @Test func theGalleryPagerFadesUnderTheHeaderToo() throws {
        let pager = ProfileGalleryPagerView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        let paging = try #require(pager.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(paging.topEdgeEffect.style == .soft)
    }
}
