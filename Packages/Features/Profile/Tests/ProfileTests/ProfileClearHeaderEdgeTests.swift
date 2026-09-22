import MediaCore
import Testing
import UIKit
@testable import Profile

/// The profile's gallery pages, and the pager over them, hide the system's top
/// edge effect under the header.
///
/// ⚠️ Left alone, the effect is a progressive blur on iOS 26.5 and a hard band
/// with a hairline on iOS 27 (measured on the inbox, For You and the
/// relationship lists); the app wants neither. A missing call shows only on a
/// device and fails to compile nowhere, so each one is pinned. See
/// `prefersClearTopEdge`.
@MainActor
struct ProfileClearHeaderEdgeTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    @Test func aGalleryPageHidesTheEffectUnderTheHeader() throws {
        let page = ProfileGalleryGridView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid, tab: .format(.activity)
        )
        let list = try #require(page.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(list.topEdgeEffect.isHidden)
    }

    /// ⚠️ THE PAGER TOO: its scroll view spans the header and draws its own
    /// effect, so pages alone leave the system's band in place.
    @Test func theGalleryPagerHidesItsEffectToo() throws {
        let pager = ProfileGalleryPagerView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        let paging = try #require(pager.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(paging.topEdgeEffect.isHidden)
    }
}
