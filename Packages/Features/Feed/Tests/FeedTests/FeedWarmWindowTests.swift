import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// What the feed warms, and when it declines to.
///
/// The warm rides the autoplay reconcile rather than living beside it, so the
/// two share one answer to "is the viewer actually looking at this?" — a
/// property that is easy to state and easy to lose the moment someone adds a
/// second trigger.
@MainActor
struct FeedWarmWindowTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func posts(_ count: Int) -> [GalleryPost] {
        (0..<count).map {
            GalleryPost(
                id: PostID("p\($0)"), kind: .photo, isRepost: false, thumbnailURL: nil,
                caption: "A caption.", publishedAtMS: 0
            )
        }
    }

    private func page() -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.content(posts(40)))
        page.layoutIfNeeded()
        return page
    }

    /// ⚠️ NOTHING WARMS DURING A FLING, and it is the same decision that stops
    /// a player being attached.
    ///
    /// A feed warmed while it is being thrown spends a request per card it will
    /// never show for longer than a glance. Both directions are asserted,
    /// because a gate that never opens is indistinguishable from one that never
    /// closes if you only ever test one side.
    @Test func aFlingWarmsNothing() {
        let page = page()
        var batches: [[GalleryPost]] = []
        page.onWarmRequested = { batches.append($0) }

        page.updateAutoplay(allowingStarts: false)
        #expect(batches.isEmpty)

        page.updateAutoplay(allowingStarts: true)
        #expect(batches.isEmpty == false)
    }

    /// ⚠️ AND THE BURST IS CAPPED, because "visible" is not always three cards.
    ///
    /// These rows self-size, and until a cell has been measured the layout
    /// holds it at its estimate — so the first reconcile after a render reports
    /// a dozen items inside the viewport. Measured before this cap existed:
    /// twelve posts asked for at once, each in its own task.
    @Test func theWarmWindowIsBounded() {
        let page = page()
        var batches: [[GalleryPost]] = []
        page.onWarmRequested = { batches.append($0) }

        page.updateAutoplay(allowingStarts: true)

        #expect(batches.first?.isEmpty == false)
        #expect((batches.first?.count ?? .max) <= 4)
    }

    /// A page still showing skeletons has nothing on screen but the shape of
    /// what is coming, and no post to name.
    @Test func aSkeletonPageWarmsNothing() {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.loading)
        page.layoutIfNeeded()
        var batches: [[GalleryPost]] = []
        page.onWarmRequested = { batches.append($0) }

        page.updateAutoplay(allowingStarts: true)

        #expect(batches.isEmpty)
    }
}
