import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The post-set surface in For You's own shape (#629): what the hashtag
/// screen — and next, search results — are laid out in.
@MainActor
struct DiscoverPostSetSurfaceTests {
    private func post(_ id: String, kind: GalleryPost.Kind = .photo) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false, thumbnailURL: nil,
            caption: id, publishedAtMS: 0, reactionCount: nil
        )
    }

    private func surface(_ style: PostSetSurfaceStyle) -> PostSetSurfaceViewController {
        let byID = ["r1", "r2", "r3", "t1"].reduce(into: [PostID: GalleryPost]()) { map, id in
            map[PostID(id)] = post(id, kind: id == "t1" ? .text : .photo)
        }
        return PostSetSurfaceViewController(
            style: style,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            // Answers in its own order, as a timeline does.
            hydrate: { ids in ids.reversed().compactMap { byID[$0] } }
        )
    }

    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Each surface style is the For You page of that shape")
    func theStyles() {
        #expect(PostSetSurfaceViewController.pageStyle(for: .cards) == .list)
        #expect(PostSetSurfaceViewController.pageStyle(for: .gallery) == .grid)
        #expect(PostSetSurfaceViewController.pageStyle(for: .discover) == .discover)
    }

    @Test("A discover page draws its lead row in the caller's order, whatever the hydration's")
    func theLeadRowKeepsTheCallersOrder() async {
        let page = surface(.discover)
        #expect(page.debugHasLeadHeader)
        page.showLeadRow(.posts([PostID("r1"), PostID("t1"), PostID("r2")]))
        await settleUntil { !page.debugLeadRowIDs.isEmpty }
        #expect(page.debugLeadRowIDs == [PostID("r1"), PostID("t1"), PostID("r2")])
    }

    @Test("Anything but posts takes the lead row away")
    func noPostsNoRow() async {
        let page = surface(.discover)
        page.showLeadRow(.posts([PostID("r1")]))
        await settleUntil { !page.debugLeadRowIDs.isEmpty }
        page.showLeadRow(.empty(message: ""))
        #expect(page.debugLeadRowIDs.isEmpty)
    }

    @Test("The other styles have no lead header, and ignore a lead row")
    func onlyDiscoverHasALead() {
        for style in [PostSetSurfaceStyle.cards, .gallery] {
            let page = surface(style)
            #expect(!page.debugHasLeadHeader)
            page.showLeadRow(.posts([PostID("r1")]))
            page.setSectionTitles(row: "Recent", list: "Top")
            #expect(page.debugLeadRowIDs.isEmpty)
        }
    }
}
