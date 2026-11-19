import CoreModels
import CoreStorage
import DesignSystem
import PlaceInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Place
@testable import PostSurfaces

/// The place page's header closes with the posts' hairline (#2289), as the
/// profile's does.
@MainActor
struct PlaceHeaderHairlineTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// Every third post text, the rest photos — the feed's usual mix.
    private func corpus(_ count: Int, allText: Bool = false) -> [GalleryPost] {
        (0..<count).map { index in
            let isText = allText || index % 3 == 2
            return GalleryPost(
                id: PostID("p\(index)"),
                kind: isText ? .text : .photo,
                isRepost: false,
                thumbnailURL: isText ? nil : URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: 1.5,
                caption: "post \(index)",
                publishedAtMS: Int64(10_000 - index)
            )
        }
    }

    private func page(_ posts: [GalleryPost], style: PostGridPageView.Style = .discover) -> PostGridPageView {
        let page = PostGridPageView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 3000)
        page.setCorpusComplete(true)
        page.render(.content(posts))
        page.layoutIfNeeded()
        return page
    }

    // MARK: - The header's hairline (#2289)

    /// The place page's header closes with the posts' hairline, as the
    /// profile's does: the list's first row draws none above it.
    @Test func thePlacesHeaderClosesWithTheHairline() {
        let place = PlaceProfileViewController(
            postIDs: [],
            placeName: "Paris • City Cluster",
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            loadPosts: { [] }, presence: SectionPresenceStore(scope: StorageScope()),
            openPost: { _, _, _ in }
        )
        #expect(place.debugHeader.drawsFootHairline)
        let rows = page(corpus(3, allText: true), style: .list)
        #expect(rows.rowSeparators(at: IndexPath(item: 0, section: 0)).top == .none, "a second line under the header")
    }
}
