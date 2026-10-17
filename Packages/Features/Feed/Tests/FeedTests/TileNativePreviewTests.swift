import CoreModels
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Every tile of every grid lifts its post with UIKit's own preview, and a
/// clip plays inside it (#1318).
@MainActor
struct TileNativePreviewTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private func corpus(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("p\(index)"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: index % 2 == 0 ? 9.0 / 16.0 : 1.5,
                caption: "post \(index)", publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)"
            )
        }
    }

    private func page() -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 3000)
        page.setCorpusComplete(true)
        page.render(.content(corpus(12)))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
        return page
    }

    private func configuration(_ page: ForYouGridPage, item: Int) -> UIContextMenuConfiguration? {
        page.collectionView(
            page.collectionView, contextMenuConfigurationForItemsAt: [page.indexPath(for: item)], point: .zero
        )
    }

    /// The shared grid offers the lift — so every surface built on it does.
    @Test func everyGridTileLiftsItsPost() throws {
        let page = page()
        let configuration = try #require(configuration(page, item: 3))
        #expect(configuration.identifier as? String == "p3")
    }

    /// Open, View Profile, then the host's author rows: the Following shelf's
    /// menu, from the seams every host already sets.
    @Test func theMenuIsTheShelfsFromTheHostsSeams() {
        let page = page()
        page.onAuthorTapped = { _ in }
        page.authorMenuActions = { _ in [PostCardMenuAction.unfollow {}] }
        let menu = page.tileMenu(for: page.posts[2], at: page.indexPath(for: 2))
        let titles = menu.children.compactMap { ($0 as? UIAction)?.title }
        #expect(titles.first == "Open")
        #expect(titles.contains("View Profile"))
        let inline = menu.children.compactMap { $0 as? UIMenu }.flatMap(\.children)
        #expect(!inline.isEmpty, "the host's author rows are missing")
    }

    /// A host that offers nothing about the author (the viewer's own posts)
    /// leaves Open alone — no Unfollow, no Report.
    @Test func ownPostsOfferOnlyOpen() {
        let page = page()
        page.authorMenuActions = { _ in [] }
        let menu = page.tileMenu(for: page.posts[0], at: page.indexPath(for: 0))
        #expect(menu.children.count == 1)
    }

    /// A clip's preview carries a live surface over its cover.
    @Test func aClipsPreviewCarriesItsSurface() {
        let clip = GalleryPost(
            id: PostID("v1"), kind: .video, isRepost: false,
            thumbnailURL: URL(string: "https://example.com/v.jpg"),
            videoURL: URL(string: "https://example.com/v.mp4"),
            aspectRatio: 9.0 / 16.0, caption: "clip", publishedAtMS: 1
        )
        let preview = ForYouPostPreviewViewController(
            post: clip, imagePipeline: ImagePipeline(fetcher: SilentFetcher()), width: 300,
            videoPlayback: VideoPlaybackController(source: StubSource(), poolSize: 1, capacity: 1)
        )
        preview.loadViewIfNeeded()
        #expect(preview.debugVideoView.superview === preview.view)
    }
}
