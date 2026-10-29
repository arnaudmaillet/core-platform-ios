import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A place opened from a warm pin draws what the app already holds of it
/// (#1863): its posts, Popular, Recent, the Likes total and the banner, before
/// the hydration — which then lands as a revalidation.
@MainActor
struct PlaceHeldCorpusTests {
    private func post(_ id: String, reactions: Int64?) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.test/\(id).jpg"),
            caption: "", publishedAtMS: 0, reactionCount: reactions
        )
    }

    /// Answers when told to: the hydration is still out while the test looks.
    private final class Gate: @unchecked Sendable {
        var isOpen = false
    }

    private func place(held: [GalleryPost], loaded: [GalleryPost], gate: Gate) -> PlaceProfileViewController {
        PlaceProfileViewController(
            postIDs: loaded.map(\.id),
            placeName: "Paris • City Cluster",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            heldMembers: held,
            loadPosts: {
                while !gate.isOpen { try? await Task.sleep(for: .milliseconds(2)) }
                return loaded
            },
            openPost: { _, _, _ in }
        )
    }

    @Test func aWarmPlaceDrawsItsPostsLikesAndBannerAtOnce() {
        let members = [post("a", reactions: 5), post("b", reactions: 7)]
        let gate = Gate()
        let page = place(held: members, loaded: members, gate: gate)
        page.beginLoading()
        #expect(Set(page.renderedActivity.map(\.id)) == [PostID("a"), PostID("b")], "the posts waited for the network")
        #expect(page.debugHeaderContent.counterValues.last == "12", "the Likes total waited")
        #expect(page.debugHeaderContent.bannerPending == false, "a banner bone for a known picture")
        gate.isOpen = true
    }

    /// A held count the app does not know is a dash, never a total that jumps.
    @Test func anUnknownCountKeepsTheDash() async {
        let held = [post("a", reactions: 5), post("b", reactions: nil)]
        let loaded = [post("a", reactions: 5), post("b", reactions: 7)]
        let gate = Gate()
        let page = place(held: held, loaded: loaded, gate: gate)
        page.beginLoading()
        #expect(page.debugHeaderContent.counterValues.last == "—")
        gate.isOpen = true
        for _ in 0..<500 where page.debugHeaderContent.counterValues.last == "—" {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(page.debugHeaderContent.counterValues.last == "12", "the hydration's total never landed")
    }

    /// Nothing held, or not all of it: the page as before.
    @Test func aPartialCorpusIsNotDrawn() {
        let full = [post("a", reactions: 1), post("b", reactions: 1)]
        #expect(FeedFeatureBuilder.allHeld([full[0], nil]).isEmpty, "a partial corpus was drawn")
        #expect(FeedFeatureBuilder.allHeld(full) == full)
        let gate = Gate()
        let page = place(held: [], loaded: full, gate: gate)
        page.beginLoading()
        #expect(page.renderedActivity.isEmpty)
        #expect(page.debugHeaderContent.bannerPending == true)
        gate.isOpen = true
    }
}
