import CoreModels
import DesignSystem
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A skeleton has the shape of what will land (#1773): Discover's mosaic,
/// the Following shelf's text row; and the lead row's bones wait for the
/// kit's delay (#1770).
@MainActor
struct SkeletonShapesTests {
    @Test func discoversColdSkeletonIsItsMosaic() {
        let time = ManualLoadingClock()
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), style: .discover)
        page.skeletonClock = time.clock
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.layoutIfNeeded()
        page.render(.loading)
        time.advance(LoadingTiming.skeletonDelay)
        #expect(page.debugBonesVisible)
        // Cards, then a mosaic chunk's tiles, then cards — not cards alone.
        #expect(page.chunk(inSection: 0) == nil)
        let chunk = page.chunk(inSection: 1)
        #expect(chunk != nil, "no mosaic in Discover's skeleton")
        #expect((chunk?.tileCount ?? 0) > 1)
        #expect(!page.offersViewAll, "a View all under the skeleton's mosaic")
    }

    @Test func theShelfsSkeletonHasItsTextRowWhenItHadOne() {
        let width: CGFloat = 393
        #expect(PostShelfSection.loadingHeight(forWidth: width, textRow: true)
            > PostShelfSection.loadingHeight(forWidth: width))
        let shelf = PostShelfSection(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), videoPlayback: nil)
        _ = shelf.apply(.init(title: "Following", posts: [], isLoading: true))
        #expect(shelf.preferredHeight(forWidth: width) == PostShelfSection.loadingHeight(forWidth: width))
        shelf.skeletonHasTextRow = true
        #expect(shelf.preferredHeight(forWidth: width) == PostShelfSection.loadingHeight(forWidth: width, textRow: true))
    }

    @Test func theLeadRowsBonesWaitForTheDelay() {
        let time = ManualLoadingClock()
        let surface = PostSetSurfaceViewController(
            style: .discover,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            // Posts that never hydrate in the test's time.
            hydrate: { _ in
                try? await Task.sleep(for: .seconds(3600))
                return []
            }
        )
        surface.skeletonClock = time.clock
        surface.showLeadRow(.posts([PostID("a"), PostID("b")]))
        #expect(surface.debugShelf?.bonesVisible == false, "bones before the delay")
        time.advance(LoadingTiming.skeletonDelay)
        #expect(surface.debugShelf?.bonesVisible == true)
    }
}
