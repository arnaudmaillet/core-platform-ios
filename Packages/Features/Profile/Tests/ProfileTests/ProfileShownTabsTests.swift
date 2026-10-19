import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Profile

/// Which tabs a profile shows (#742, #1422): a tab only for a source with
/// something in it — Posts included, but for the viewer's own.
@MainActor
struct ProfileShownTabsTests {
    private let all = ProfileTab.ownTabs

    private func post(_ id: String) -> GalleryPost {
        GalleryPost(id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil, caption: id, publishedAtMS: 0)
    }

    private func snapshot(
        posts: ProfileViewModel.GalleryPageState = .empty(message: ""),
        tagged: ProfileViewModel.GalleryPageState = .empty(message: "")
    ) -> ProfileViewModel.GallerySnapshot {
        var snapshot = ProfileViewModel.GallerySnapshot(activity: posts, media: posts)
        snapshot.tagged = tagged
        return snapshot
    }

    /// Someone else's profile, no posts but tagged ones: Tagged alone.
    @Test func noPostsButTaggedShowsTaggedAlone() {
        let shown = ProfileViewController.shownTabs(
            all, in: snapshot(tagged: .content([post("t")])), isOwnProfile: false
        )
        #expect(shown == [.tagged])
    }

    /// Nothing anywhere: no tab has anything — the screen then shows Posts
    /// alone, its one "No Posts Yet".
    @Test func nothingAnywhereLeavesPostsToTheScreen() {
        #expect(ProfileViewController.shownTabs(all, in: snapshot(), isOwnProfile: false).isEmpty)
    }

    /// The viewer's own Posts stays even empty: the invitation to post.
    @Test func theOwnPostsStaysEmpty() {
        let shown = ProfileViewController.shownTabs(
            all, in: snapshot(tagged: .content([post("t")])), isOwnProfile: true
        )
        #expect(shown == [.format(.activity), .tagged])
    }

    /// A source still loading waits: no tab that might leave.
    @Test func aLoadingSourceWaits() {
        let shown = ProfileViewController.shownTabs(
            all, in: snapshot(posts: .loading, tagged: .loading), isOwnProfile: false
        )
        #expect(shown.isEmpty)
    }

    /// Posts with something in them, and Tagged: both, as before.
    @Test func everySourceWithPostsHasItsTab() {
        let shown = ProfileViewController.shownTabs(
            all, in: snapshot(posts: .content([post("p")]), tagged: .content([post("t")])), isOwnProfile: false
        )
        #expect(shown == [.format(.activity), .tagged])
    }

    /// A private profile, not followed: Posts is the lock, never a tab;
    /// Tagged with posts is the only one, drawn plainly — no lock line, no
    /// section title (#1445).
    @Test func aPrivateProfileShowsTaggedAlonePlainly() {
        var locked = snapshot(tagged: .content([post("t")]))
        locked.restrictEmptyPages()
        #expect(ProfileViewController.shownTabs(all, in: locked, isOwnProfile: false) == [.tagged])
        let page = ProfileGalleryPagerView.pageState(locked.tagged, for: .tagged)
        guard case .content(let posts) = page else {
            Issue.record("Tagged is not plain content: \(page)")
            return
        }
        #expect(posts.map(\.id.rawValue) == ["t"])
    }

    /// A private profile with nothing visible: no tab; the screen shows the
    /// lock alone.
    @Test func aPrivateProfileWithNothingVisibleIsTheLockAlone() {
        var locked = snapshot()
        locked.restrictEmptyPages()
        #expect(ProfileViewController.shownTabs(all, in: locked, isOwnProfile: false).isEmpty)
        guard case .status(let status) = ProfileGalleryPagerView.pageState(locked.activity, for: .format(.activity)) else {
            Issue.record("Posts is not the lock")
            return
        }
        #expect(status.title == ProfileViewModel.restrictedTitle)
    }
}
