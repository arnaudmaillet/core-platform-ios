import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// ⚠️ ONE CONTRACT FOR EVERY MEDIA TILE (#1270, epic #1269): every host of a
/// `ForYouGridPage` other than For You describes a tile's opening through
/// `ForYouGridPage.heroOrigin`, and the origin carries every hook For You's own
/// tiles fly with — the landing's playhead above all, whose absence restarted
/// a tile's clip after a close onto the same post.
@MainActor
struct TileHeroOriginTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func corpus(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("p\(index)"), kind: .video, isRepost: false,
                thumbnailURL: URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: 1, caption: "post \(index)", publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)",
                reactionCount: 100
            )
        }
    }

    private func page(style: ForYouGridPage.Style) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 3000)
        page.setCorpusComplete(true)
        page.render(.content(corpus(12)))
        page.layoutIfNeeded()
        return page
    }

    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func theOriginCarriesEveryTileHook(style: ForYouGridPage.Style) throws {
        let page = page(style: style)
        let tapped = try #require(page.posts.first)
        let origin = page.heroOrigin(
            opening: tapped, stream: Array(page.posts.prefix(4)), in: page,
            textReveal: nil, continuation: nil
        )
        #expect(origin.post.id == tapped.id)
        #expect(origin.stream.map(\.id) == page.posts.prefix(4).map(\.id))
        #expect(origin.donateLiveMedia != nil, "the card takes off as a still")
        #expect(origin.adoptLandingLiveMedia != nil, "a same-post close restarts the tile's clip")
        #expect(origin.landingMediaIsReady != nil, "the card leaves before the tile draws")
        #expect(origin.returnLiveMedia != nil && origin.pauseReturnLiveMedia != nil)
        #expect(origin.adoptReturnLiveMedia != nil && origin.returnLandingIsReady != nil)
        #expect(origin.restingOverlay != nil, "a close lands bare")
        #expect(origin.followMediaPage != nil)
    }

    /// The host's own staging runs after the page has pinned itself.
    @Test func theHostsStagingRunsAfterThePin() throws {
        let page = page(style: .grid)
        let tapped = try #require(page.posts.first)
        var staged = 0
        let origin = page.heroOrigin(
            opening: tapped, stream: [tapped], in: page,
            textReveal: nil, willStageDismissal: { staged += 1 }, continuation: nil
        )
        origin.willStageDismissal()
        #expect(staged == 1)
    }
}
