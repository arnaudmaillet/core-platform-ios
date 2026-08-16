import CoreModels
import FeedInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The place gallery as a PLACE PROFILE: popularity-ranked by default, with
/// the follow-this-place toggle in its header.
@MainActor
struct ClusterGalleryTests {
    private func post(_ id: String, reactions: Int64?, publishedAtMS: Int64 = 0) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: publishedAtMS, reactionCount: reactions
        )
    }

    private func makeGallery(
        following: ClusterGalleryFollowing? = nil,
        posts: [GalleryPost] = []
    ) -> ClusterGalleryViewController {
        ClusterGalleryViewController(
            postIDs: posts.map(\.id),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            following: following,
            loadPosts: { posts },
            openPost: { _, _, _ in }
        )
    }

    // MARK: - Popularity ordering

    /// The gallery's default order is popularity DESCENDING — the trending
    /// rule verbatim, so ties fall to recency then id and a re-render can't
    /// reshuffle equals.
    @Test func theGalleryRanksByPopularityDescending() {
        let ranked = ClusterGalleryViewController.ranked([
            post("post-1", reactions: 40),
            post("post-2", reactions: 900),
            post("post-3", reactions: nil), // no counter → ranks as 0, last
            post("post-4", reactions: 90),
        ])
        #expect(ranked.map(\.id.rawValue) == ["post-2", "post-4", "post-1", "post-3"])
    }

    /// And the hydration path renders THROUGH that order: whatever order the
    /// members arrive in, the grid's content is popularity-first.
    @Test func hydrationRendersInRankedOrder() async {
        let gallery = makeGallery(posts: [
            post("post-1", reactions: 5),
            post("post-2", reactions: 70),
            post("post-3", reactions: 20),
        ])
        gallery.beginLoading()
        for _ in 0..<50 where gallery.renderedPosts.isEmpty { await Task.yield() }
        #expect(gallery.renderedPosts.map(\.id.rawValue) == ["post-2", "post-3", "post-1"])
    }

    // MARK: - The follow toggle

    /// The header's trailing button mirrors the injected state and flips it:
    /// Follow → toggle → Following → toggle → Follow, always reading the
    /// caller's answer rather than caching its own.
    @Test func theFollowButtonTogglesTheInjectedState() throws {
        var followed = false
        let gallery = makeGallery(following: ClusterGalleryFollowing(
            isFollowing: { followed },
            toggle: { followed.toggle(); return followed }
        ))
        gallery.loadViewIfNeeded()

        let button = try #require(gallery.navigationItem.rightBarButtonItem?.customView as? UIButton)
        func label() -> String? {
            button.configuration?.attributedTitle.map { String($0.characters) }
        }
        #expect(label() == "Follow")

        button.sendActions(for: .primaryActionTriggered)
        #expect(followed, "the toggle reached the caller's store")
        #expect(label() == "Following")

        button.sendActions(for: .primaryActionTriggered)
        #expect(!followed)
        #expect(label() == "Follow")
    }

    /// A gallery whose subject has no followable identity shows no button at
    /// all — an inert heart would promise a feature the caller can't honor.
    @Test func withoutAFollowSeamTheHeaderStaysBare() {
        let gallery = makeGallery(following: nil)
        gallery.loadViewIfNeeded()
        #expect(gallery.navigationItem.rightBarButtonItem == nil)
    }
}
