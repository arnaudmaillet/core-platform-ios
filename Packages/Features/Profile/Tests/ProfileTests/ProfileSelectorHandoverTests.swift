import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import ProfileInterface
import Testing
import UIKit
@testable import Profile

/// Where a pushed profile's selector ends up, and what else is in the bar
/// with it.
///
/// ⚠️ **THERE IS ONE SELECTOR NOW.** This file was about the hand-over between
/// two — one filling the page's column, one hugging the navigation bar's title
/// slot, cross-fading as the identity block scrolled away. The strip sits in
/// the navigation controller's bottom toolbar for this screen's whole life, so
/// what is left to get wrong is not which copy is visible but whether the one
/// copy is in the bar at all.
@MainActor
struct ProfileSelectorHandoverTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private actor GalleryProvider: ProfileProviding {
        func currentUserProfile() async throws -> UserProfile { profile }
        func profile(id: ProfileID) async throws -> UserProfile { profile }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
            .me
        }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { profile }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { profile }

        private let profile = UserProfile(
            id: ProfileID("prof-1"),
            handle: "ada",
            displayName: "Ada Lovelace",
            bio: "Countess of computing",
            avatarURL: nil,
            websiteURL: nil,
            isVerified: true,
            followerCount: .exact(12),
            followingCount: .exact(34),
            reactionCount: .exact(56)
        )
    }

    /// An empty gallery is still a gallery: the selectors exist because the
    /// screen HAS tabs to choose between, not because any of them has content.
    private struct EmptyGallery: ProfileGalleryProviding {
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] {
            []
        }

        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    /// A gallery with something in every source it is given (#742): posts,
    /// reposts among them, and posts that tag the profile.
    private struct StockedGallery: ProfileGalleryProviding {
        var reposts = true
        var tagged = true

        private static func post(_ id: String, repost: Bool = false) -> GalleryPost {
            GalleryPost(id: PostID(id), kind: .photo, isRepost: repost, thumbnailURL: nil, caption: id, publishedAtMS: 1)
        }

        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] {
            [Self.post("p1")] + (reposts ? [Self.post("r1", repost: true)] : [])
        }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] {
            tagged ? [Self.post("t1")] : []
        }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    /// A loaded screen with its view up — the selectors are only placed once
    /// the profile has a gallery to filter.
    private func loadedScreen(
        source: ProfileViewModel.Source = .currentUser,
        trayPlacement: ProfileTrayPlacement = .navigationToolbar,
        gallery: any ProfileGalleryProviding = StockedGallery()
    ) async -> ProfileViewController? {
        let viewModel = ProfileViewModel(repository: GalleryProvider(), gallery: gallery, source: source)
        viewModel.viewDidLoad()
        for _ in 0..<60 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard viewModel.hasGallery else {
            Issue.record("the profile never produced a gallery to select within")
            return nil
        }
        let screen = ProfileViewController(
            viewModel: viewModel,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            onLogout: nil,
            trayPlacement: trayPlacement
        )
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.view.layoutIfNeeded()
        return screen
    }

    /// ⚠️ **A PUSHED PROFILE'S STRIP IS A BOTTOM-LEADING TOOLBAR ITEM
    /// (#728).** The owner's call: the tab root keeps its `UITabAccessory`, a
    /// pushed profile carries the strip in the stack's toolbar at the leading
    /// corner, at its intrinsic width, on the item's own platter — the
    /// relations screen's arrangement. The source filter still leads the
    /// navigation bar.
    ///
    /// The non-empty `toolbarItems` is load-bearing:
    /// `SnapFeedViewController.successorUsesToolbar` reads it to leave the
    /// shared toolbar up when a post pushed from here is popped.
    @Test func aPushedProfileHostsTheSelectorBottomLeading() async {
        guard let screen = await loadedScreen(source: .profile(ProfileID("prof-2"))) else { return }
        let items = screen.toolbarItems ?? []
        #expect(items.count == 2)
        #expect(items.first === screen.selectorItem, "the strip does not lead the toolbar")
        #expect(items.first?.customView is PagedTabBar, "the leading item is not the format selector")
        #expect((items.first?.customView as? PagedTabBar)?.hosting == .platter,
                "the strip draws a capsule inside the item's platter")
        #expect(screen.selectorAccessory == nil, "a pushed profile hung a tab accessory")
    }

    /// The Profile tab's root keeps the strip in the tab bar's accessory, as
    /// it always had (#728) — no toolbar.
    @Test func theTabRootHostsTheSelectorInTheTabAccessory() async {
        guard let screen = await loadedScreen(source: .profile(ProfileID("prof-2")), trayPlacement: .aboveBottomSafeArea)
        else { return }
        let band = try? #require(screen.selectorAccessory?.hostView)
        #expect(band?.subviews.compactMap { $0 as? PagedTabBar }.count == 1,
                "the format selector is not in the band")
        #expect(screen.toolbarItems?.isEmpty != false, "the tab root raised a toolbar")
        #expect(screen.selectorItem == nil)
    }

    /// ⚠️ **WITHOUT THIS THE FILTER REPLACES THE BACK BUTTON**, and UIKit
    /// disables the interactive pop along with it, silently — on the one screen
    /// in this pair that has a back button to lose.
    @Test func theLeadingFilterSupplementsTheBackButton() async {
        guard let screen = await loadedScreen() else { return }
        #expect(screen.navigationItem.leftItemsSupplementBackButton == true)
        #expect(screen.navigationItem.hidesBackButton == false)
    }

    /// ⚠️ **NO SOURCE FILTER IN YOUR OWN PROFILE'S BAR (#772).** It led the
    /// bar (All / Posts / Reposts / Tagged); Reposts and Tagged are tabs at
    /// the foot now, as on anyone else's profile.
    @Test func yourOwnProfileHasNoSourceFilterInTheBar() async {
        guard let screen = await loadedScreen() else { return }
        #expect(screen.navigationItem.leftBarButtonItems?
            .contains { $0.accessibilityLabel == "Content source" } != true,
            "your own profile kept the source filter")
        for index in screen.debugTabTitles.indices {
            screen.selectTab(at: index)
            #expect(screen.navigationItem.leftBarButtonItems?
                .contains { $0.accessibilityLabel == "Content source" } != true,
                "the source filter came back on tab \(index)")
        }
    }

    /// ⚠️ **POSTS · REPOSTS · TAGGED IN THE TAB ROOT'S ACCESSORY (#772)**, each
    /// with something in it — Saved and Liked join only once they hold
    /// something (#742).
    @Test func yourOwnProfileListsRepostsAndTaggedInTheAccessory() async {
        guard let screen = await loadedScreen(trayPlacement: .aboveBottomSafeArea) else { return }
        #expect(screen.debugTabTitles == ["Posts", "Reposts", "Tagged"])
        #expect(screen.debugSelectorTitles == ["Posts", "Reposts", "Tagged"])
        #expect(screen.debugPageCount == 3)
        #expect(screen.selectorAccessory != nil, "no selector in the accessory")
        #expect(screen.debugActivePageIndex == 0, "it does not open on Posts")
    }

    /// And a source with nothing in it has no tab on your own profile either.
    @Test func yourOwnEmptySourceHasNoTab() async {
        guard let screen = await loadedScreen(
            trayPlacement: .aboveBottomSafeArea, gallery: StockedGallery(reposts: false)
        ) else { return }
        #expect(screen.debugTabTitles == ["Posts", "Tagged"])
        #expect(screen.debugSelectorTitles == ["Posts", "Tagged"])
    }

    // MARK: - Someone else's profile (#696)

    /// ⚠️ POSTS · REPOSTS · TAGGED AT THE FOOT, NO FILTER UP TOP (#696).
    /// Someone else's sources are pages now, switched by the selector or a
    /// swipe, so the bar's source filter is gone. It opens on Posts.
    @Test func someoneElsesProfileHasPostsRepostsTaggedAtTheFoot() async {
        guard let screen = await loadedScreen(source: .profile(ProfileID("prof-2"))) else { return }
        #expect(screen.selectorItem?.customView is PagedTabBar, "no selector at the foot")
        #expect(screen.debugTabTitles == ["Posts", "Reposts", "Tagged"])
        #expect(screen.debugPageCount == 3)
        #expect(screen.debugActivePageIndex == 0, "it does not open on Posts")
        #expect(screen.navigationItem.leftBarButtonItems?
            .contains { $0.accessibilityLabel == "Content source" } != true,
            "someone else's profile kept the source filter")
    }

    /// The viewer's own with no reposts, no tags and nothing saved: Liked has
    /// no source to fill it (no API answers it) and the rest are empty, so
    /// Posts alone — no selector (#742, #772).
    @Test(arguments: [ProfileTrayPlacement.navigationToolbar, .aboveBottomSafeArea])
    func yourOwnProfileWithNothingElseIsPostsAlone(placement: ProfileTrayPlacement) async {
        guard let screen = await loadedScreen(
            trayPlacement: placement, gallery: StockedGallery(reposts: false, tagged: false)
        ) else { return }
        #expect(screen.debugTabTitles == ["Posts"])
        #expect(screen.debugPageCount == 1)
        #expect(screen.selectorItem == nil, "a selector with one tab")
        #expect(screen.selectorAccessory == nil, "an accessory with one tab")
        #expect(screen.toolbarItems?.isEmpty != false)
    }

    // MARK: - Empty sources (#742)

    /// ⚠️ NO TAB FOR A SOURCE WITH NOTHING IN IT: no reposts, no Reposts —
    /// not in the selector, not as a page.
    @Test func anEmptySourceHasNoTabAndNoPage() async {
        guard let screen = await loadedScreen(
            source: .profile(ProfileID("prof-2")), gallery: StockedGallery(reposts: false)
        ) else { return }
        #expect(screen.debugTabTitles == ["Posts", "Tagged"])
        #expect(screen.debugSelectorTitles == ["Posts", "Tagged"])
        #expect(screen.debugPageCount == 2)
        #expect(screen.selectorItem != nil)
    }

    /// Posts alone is no selector: no toolbar item on a pushed profile, no
    /// accessory on the tab root.
    @Test(arguments: [ProfileTrayPlacement.navigationToolbar, .aboveBottomSafeArea])
    func postsAloneIsNoSelector(placement: ProfileTrayPlacement) async {
        guard let screen = await loadedScreen(
            source: .profile(ProfileID("prof-2")), trayPlacement: placement,
            gallery: StockedGallery(reposts: false, tagged: false)
        ) else { return }
        #expect(screen.debugTabTitles == ["Posts"])
        #expect(screen.debugPageCount == 1)
        #expect(screen.selectorItem == nil, "a toolbar selector with one tab")
        #expect(screen.selectorAccessory == nil, "a tab accessory with one tab")
    }

    /// On Posts, with no page to its left, a drag anywhere dismisses a
    /// pushed profile; on Reposts or Tagged a rightward swipe is the previous
    /// page, and only the edge dismisses (#696).
    @Test func aPushedProfileDismissesFromAnywhereOnlyOnPosts() async {
        guard let screen = await loadedScreen(source: .profile(ProfileID("prof-2"))) else { return }
        #expect(ProfileDismissalPolicy.allowsFullWidthDismissal(
            activeIndex: screen.debugActivePageIndex, isPushed: true
        ))
        for index in [1, 2] {
            screen.selectTab(at: index)
            #expect(screen.debugActivePageIndex == index)
            #expect(!ProfileDismissalPolicy.allowsFullWidthDismissal(
                activeIndex: screen.debugActivePageIndex, isPushed: true
            ), "page \(index) dismissed full-width")
        }
    }
}
