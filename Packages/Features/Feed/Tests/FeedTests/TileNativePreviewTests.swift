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

    private func makePage() -> ForYouGridPage {
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
        let page = makePage()
        let lift = try #require(configuration(page, item: 3))
        #expect(lift.identifier as? String == "p3")
    }

    /// Open, View Profile, then the host's author rows: the Following shelf's
    /// menu, from the seams every host already sets.
    @Test func theMenuIsTheShelfsFromTheHostsSeams() {
        let page = makePage()
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
        let page = makePage()
        page.authorMenuActions = { _ in [] }
        let menu = page.tileMenu(for: page.posts[0], at: page.indexPath(for: 0))
        #expect(menu.children.count == 1)
    }

    // MARK: - List cards: the media alone (#1377)

    private func listPosts() -> [GalleryPost] {
        [
            GalleryPost(
                id: PostID("photo"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.com/photo.jpg"), aspectRatio: 1,
                caption: "New city, same habits.", publishedAtMS: 3,
                authorID: ProfileID("a1"), authorName: "Noah", authorHandle: "noah"
            ),
            GalleryPost(
                id: PostID("text"), kind: .text, isRepost: false, thumbnailURL: nil,
                caption: "Third coffee.", publishedAtMS: 2,
                authorID: ProfileID("a2"), authorName: "Yuki", authorHandle: "yuki"
            ),
            GalleryPost(
                id: PostID("set"), kind: .photo, isRepost: false,
                pages: (0..<4).map {
                    GalleryPost.MediaPage(thumbnailURL: URL(string: "https://example.com/s\($0).jpg"), aspectRatio: 1)
                },
                caption: "Four of them.", publishedAtMS: 1,
                authorID: ProfileID("a3"), authorName: "Lena", authorHandle: "lena"
            ),
        ]
    }

    /// A list page in a window: the previews need the cell on screen.
    private func hostingList(_ body: (ForYouGridPage) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 3000))
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list)
        page.frame = window.bounds
        window.addSubview(page)
        window.isHidden = false
        defer { window.isHidden = true }
        page.setCorpusComplete(true)
        page.render(.content(listPosts()))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
        try body(page)
    }

    private func row(_ page: ForYouGridPage, item: Int) throws -> PostGridListRowCell {
        try #require(page.collectionView.cellForItem(at: page.indexPath(for: item)) as? PostGridListRowCell)
    }

    private func press(_ page: ForYouGridPage, item: Int, at point: CGPoint) throws -> UIContextMenuConfiguration? {
        let cell = try row(page, item: item)
        return page.collectionView(
            page.collectionView, contextMenuConfigurationForItemsAt: [page.indexPath(for: item)],
            point: cell.convert(point, to: page.collectionView)
        )
    }

    /// Only a press that starts on the media lifts a list card: the caption,
    /// the header and the card's margins lift nothing.
    @Test func aListCardLiftsOnlyFromItsMedia() throws {
        try hostingList { page in
            let cell = try row(page, item: 0)
            let media = try #require(cell.mediaHeroRect)
            #expect(try press(page, item: 0, at: CGPoint(x: media.midX, y: media.midY)) != nil)
            #expect(try press(page, item: 0, at: CGPoint(x: media.midX, y: media.minY - 8)) == nil, "the header")
            #expect(try press(page, item: 0, at: CGPoint(x: media.midX, y: media.maxY + 8)) == nil, "below the media")
            #expect(try press(page, item: 0, at: CGPoint(x: 2, y: media.midY)) == nil, "the card's margin")
        }
    }

    /// Off the media a long press does nothing — not even the card's open
    /// on release: the hold swallows it there, and only there. The action
    /// row's controls keep their own press, the media its lift.
    @Test func offTheMediaALongPressIsSwallowed() throws {
        try hostingList { page in
            let cell = try row(page, item: 0)
            let media = try #require(cell.mediaHeroRect)
            func swallows(_ point: CGPoint, in cell: UIView) -> Bool {
                page.swallowsHold(at: cell.convert(point, to: page.collectionView))
            }
            #expect(swallows(CGPoint(x: media.midX, y: media.minY - 8), in: cell), "the caption")
            #expect(!swallows(CGPoint(x: media.midX, y: media.midY), in: cell), "the media lifts")
            let control = try #require(Self.firstControl(in: cell))
            let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: cell)
            #expect(!swallows(center, in: cell), "a control keeps its press")
            let text = try row(page, item: 1)
            #expect(swallows(CGPoint(x: text.bounds.midX, y: 30), in: text), "a text card")
        }
    }

    private static func firstControl(in view: UIView) -> UIControl? {
        for subview in view.subviews where !subview.isHidden && subview.alpha > 0.01 {
            if let control = subview as? UIControl, control.isUserInteractionEnabled, control.bounds.width > 0 {
                return control
            }
            if let found = firstControl(in: subview) { return found }
        }
        return nil
    }

    /// A text-only card has no preview anywhere on it.
    @Test func aTextCardHasNoPreview() throws {
        try hostingList { page in
            let cell = try row(page, item: 1)
            #expect(cell.mediaHeroRect == nil)
            for y in stride(from: 4, to: cell.bounds.height, by: 24) {
                #expect(try press(page, item: 1, at: CGPoint(x: cell.bounds.midX, y: y)) == nil)
            }
            #expect(page.tilePreview(at: page.indexPath(for: 1)) == nil)
        }
    }

    /// The lift and the drop are the media's rect and corners, never the
    /// card's.
    @Test func aListCardsPreviewIsItsMedia() throws {
        try hostingList { page in
            let cell = try row(page, item: 0)
            let media = try #require(cell.mediaHeroRect)
            let preview = try #require(page.tilePreview(at: page.indexPath(for: 0)))
            #expect(preview.view !== cell.contentView, "the card itself stays in place")
            let shown = preview.view.convert(try #require(preview.parameters.visiblePath).bounds, to: cell)
            #expect(abs(shown.minX - media.minX) < 0.5 && abs(shown.minY - media.minY) < 0.5)
            #expect(abs(shown.width - media.width) < 0.5 && abs(shown.height - media.height) < 0.5)
            #expect(shown.height < cell.bounds.height - 40, "the card's header and text are outside it")
        }
    }

    /// On a carousel, the page on screen: page 2 lifts page 2's rect.
    @Test func aCarouselLiftsThePageOnScreen() throws {
        try hostingList { page in
            let cell = try row(page, item: 2)
            let first = try #require(cell.mediaHeroRect)
            cell.setMediaPage(1, animated: false)
            cell.layoutIfNeeded()
            let second = try #require(cell.mediaHeroRect)
            #expect(second != first)
            let preview = try #require(page.tilePreview(at: page.indexPath(for: 2)))
            let shown = preview.view.convert(try #require(preview.parameters.visiblePath).bounds, to: cell)
            #expect(abs(shown.minX - second.minX) < 0.5 && abs(shown.width - second.width) < 0.5)
            #expect(try press(page, item: 2, at: CGPoint(x: second.midX, y: second.midY)) != nil)
        }
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
