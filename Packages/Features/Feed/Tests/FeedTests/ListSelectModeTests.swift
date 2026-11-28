import CoreModels
import CoreStorage
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import PostSurfaces

/// A List page's select mode (the profile's Saved, the owner 2026-11-28):
/// History's mechanics on the list's cards — a tap selects a card instead of
/// opening it, nothing lifts, a press off the media is not swallowed, every
/// card rests under its circle, and leaving drops the selection.
@MainActor
struct ListSelectModeTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// The first post a photograph, the rest text, so every card is on screen.
    private func posts(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            let isText = index > 0
            return GalleryPost(
                id: PostID("p\(index)"), kind: isText ? .text : .photo, isRepost: false,
                thumbnailURL: isText ? nil : URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: 1, caption: "post \(index)", publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)",
                reactionCount: 3
            )
        }
    }

    private func page() -> (any PostGridPage, PostGridPageView) {
        let grid = PostGridPageView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list,
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            withheldPosts: UnavailablePosts(viewerEvents: ViewerEvents())
        )
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 1_200)
        grid.setCorpusComplete(true)
        return (grid, grid)
    }

    private func card(_ grid: PostGridPageView, _ id: String) throws -> PostGridListRowCell {
        grid.layoutIfNeeded()
        return try #require(grid.debugCell(for: PostID(id)) as? PostGridListRowCell)
    }

    @Test func aListPageSelectsInsteadOfOpening() throws {
        let (page, grid) = page()
        var opened = 0
        page.onPostTapped = { _, _, _ in opened += 1 }
        var reported: [[PostID]] = []
        page.onRowSelectionChanged = { reported.append($0) }
        page.show(.content(posts(4)))
        page.layoutIfNeeded()
        #expect(!page.isSelectingRows)
        #expect(try card(grid, "p0").debugCardTakesTouches)
        page.setSelectingRows(true)
        #expect(page.isSelectingRows)
        for item in [2, 0] {
            let path = IndexPath(item: item, section: 0)
            grid.collectionView.selectItem(at: path, animated: false, scrollPosition: [])
            grid.collectionView(grid.collectionView, didSelectItemAt: path)
        }
        #expect(opened == 0, "a tap opened the post in the select mode")
        #expect(page.selectedRowPostIDs == [PostID("p0"), PostID("p2")], "in the page's order")
        #expect(reported.last == [PostID("p0"), PostID("p2")])
        #expect(grid.collectionView(grid.collectionView, contextMenuConfigurationForItemsAt: [IndexPath(item: 0, section: 0)], point: .zero) == nil,
                "a card lifted its menu in the select mode")

        let media = try card(grid, "p0")
        #expect(!media.debugCardTakesTouches, "a part of the card still takes its own tap in the select mode")
        let band = media.convert(CGPoint(x: media.bounds.midX, y: 20), to: grid.collectionView)
        #expect(!grid.swallowsHold(at: band), "a press off the media is swallowed instead of selecting")
        #expect(media.debugSelectionMark == (shown: true, checked: true), "a selected card wears no check")
        let text = try card(grid, "p1")
        #expect(text.debugSelectionMark == (shown: true, checked: false), "a card wears no circle in the select mode")

        page.setSelectingRows(false)
        #expect(!page.isSelectingRows)
        #expect(page.selectedRowPostIDs.isEmpty)
        #expect(reported.last == [])
        #expect(try card(grid, "p0").debugCardTakesTouches, "the card did not wake")
        #expect(!(try card(grid, "p0").debugSelectionMark.shown))
    }

    /// A grid page has no select mode.
    @Test func aGridPageHasNoSelectMode() {
        let grid = PostGridPageView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid,
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            withheldPosts: UnavailablePosts(viewerEvents: ViewerEvents())
        )
        grid.setSelectingRows(true)
        #expect(!grid.isSelectingRows)
    }
}
