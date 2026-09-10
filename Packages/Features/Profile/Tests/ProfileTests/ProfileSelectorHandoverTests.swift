import CoreModels
import DesignSystem
import MediaCore
import PostGrid
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
            reactionCount: .exact(56),
            viewCount: .exact(78)
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

    /// A loaded screen with its view up — the selectors are only placed once
    /// the profile has a gallery to filter.
    private func loadedScreen() async -> ProfileViewController? {
        let viewModel = ProfileViewModel(repository: GalleryProvider(), gallery: EmptyGallery())
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
            onLogout: nil
        )
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.view.layoutIfNeeded()
        return screen
    }

    /// ⚠️ **A PUSHED PROFILE PRESENTS NO TOOLBAR AT ALL NOW.** The selector and
    /// the source filter shared one, and fought over it — `placeSelectors`
    /// prepended the strip and `placeSourceTray` assigned the tray outright,
    /// last writer won, and the screen shipped with a filter glyph on the right
    /// and an empty space where the format tabs belong. Neither is in a toolbar
    /// any more: the strip is in a `UITabAccessory` (which a pushed screen CAN
    /// host — measured on the search results, `env=regular`, a 360x48 container
    /// at the foot, with `hidesBottomBarWhenPushed` set) and the filter leads
    /// the navigation bar.
    ///
    /// The empty `toolbarItems` is load-bearing rather than incidental:
    /// `SnapFeedViewController.successorUsesToolbar` reads it to decide whether
    /// to leave the shared toolbar up when a post pushed from here is popped.
    @Test func aPushedProfilePresentsNoToolbarItems() async {
        guard let screen = await loadedScreen() else { return }
        #expect(screen.toolbarItems?.isEmpty != false,
                "a toolbar and an accessory both claim the bottom and neither yields")
        let band = try? #require(screen.selectorAccessory?.hostView)
        #expect(band?.subviews.compactMap { $0 as? PagedTabBar }.count == 1,
                "the format selector is not in the band")
        #expect(screen.navigationItem.leftBarButtonItems?
            .contains { $0.accessibilityLabel == "Content source" } == true,
            "the source filter is not leading the bar")
    }

    /// ⚠️ **WITHOUT THIS THE FILTER REPLACES THE BACK BUTTON**, and UIKit
    /// disables the interactive pop along with it, silently — on the one screen
    /// in this pair that has a back button to lose.
    @Test func theLeadingFilterSupplementsTheBackButton() async {
        guard let screen = await loadedScreen() else { return }
        #expect(screen.navigationItem.leftItemsSupplementBackButton == true)
        #expect(screen.navigationItem.hidesBackButton == false)
    }

    /// ⚠️ **A SYSTEM ITEM, AND THE SHAPE IS THE REASON.** Wrapped in a button
    /// the glyph came out in a 59x44 platter — an OVAL beside a chevron that is
    /// a 44pt circle — because the button carries its own content insets and
    /// UIKit sizes the platter around whatever it is given.
    @Test func theSourceFilterHasNoCustomViewToInflateItsPlatter() async {
        guard let screen = await loadedScreen() else { return }
        let filter = screen.navigationItem.leftBarButtonItems?
            .first { $0.accessibilityLabel == "Content source" }
        #expect(filter?.customView == nil)
        #expect(filter?.menu != nil, "the item is the menu host; nothing wraps it")
    }

    // MARK: - Which one is on screen

    /// At the top of the profile the selector is the inline one, and the
    /// ⚠️ **SIX TESTS WENT WITH THE MECHANISM THEY DROVE.** There were two
    /// selector copies — an inline one in the header's slot and a docked one in
    /// the navigation bar — crossfading at a threshold, and four tests pushed
    /// `debugSetBarDocked` across it while two more checked that selecting on
    /// one copy mirrored to the other without feeding back. The strip lives at
    /// the foot of the screen now and never moves: no threshold, no crossfade,
    /// no second copy to mirror into.
    ///
    /// ⚠️ AND ONE OF THEM WAS ALREADY VACUOUS.
    /// `theRestingSelectorSurvivesTheBarRewritingItsAlpha` poked
    /// `navigationItem.titleView?.alpha` — but on this screen the title view
    /// was the ZERO-SIZED empty view the leading-selector install planted, never
    /// the docked bar. It would have passed unchanged after the selector left
    /// the bar entirely. Deleting it removes a test that proved nothing.
    ///
    /// What survives below is the pair that was never about the hand-over: the
    /// source filter keeping its place across a tab change.

    /// ⚠️ **THE DEFECT THESE TWO WERE WRITTEN FOR IS GONE WITH ITS
    /// MECHANISM.** They watched a bar item's custom view being STOLEN: the
    /// inline tray was lazy, its initialiser wrapped the source button in a
    /// glass capsule and adopted it as a subview, and building the tray
    /// therefore took the button off the toolbar — leaving a bar item with an
    /// empty custom view, a full-width blank capsule at the foot. It only
    /// showed after a tab change, because that was the only thing that built
    /// the tray, which is why the first tab looked right and the second did
    /// not. There is no tray and no custom view now; the filter is a system bar
    /// item and nothing can adopt it.
    ///
    /// What is still worth pinning is what the tab change was always supposed
    /// to do to it: the filter belongs to a FORMAT tab, so it goes when there
    /// is no format to filter and comes back when there is.
    @Test func theSourceFilterFollowsWhetherTheTabHasAFormat() async {
        guard let screen = await loadedScreen() else { return }
        let filter = screen.navigationItem.leftBarButtonItems?
            .first { $0.accessibilityLabel == "Content source" }
        #expect(filter != nil)

        for index in [1, 2, 0, 1] {
            screen.selectTab(at: index)
            #expect(screen.navigationItem.leftBarButtonItems?
                .contains { $0 === filter } == true,
                "the filter left the bar on tab \(index)")
            #expect(filter?.customView == nil, "something wrapped the filter")
        }
    }
}
