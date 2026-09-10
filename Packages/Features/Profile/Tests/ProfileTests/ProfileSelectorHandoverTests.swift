import CoreModels
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

/// The hand-over between the profile's two selectors.
///
/// There are two of them — one filling the page's column, one hugging in the
/// navigation bar's title slot — because the change between them is a crossfade,
/// and a single re-parented view cannot fade out of one place while fading into
/// another. Two views means two things to keep straight, and both of them have
/// already been wrong once: which is visible at rest, and whether they agree on
/// the selected tab.
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
    /// source button keeping its place in the trailing run across a tab change.

    /// looked right and the second did not.
    @Test func theSourceButtonKeepsItsPlaceAfterChangingTab() async {
        guard let screen = await loadedScreen() else { return }
        guard let button = screen.toolbarItems?.compactMap(\.customView).last else {
            Issue.record("the toolbar had no item to lose")
            return
        }
        // Headless, a bar item's custom view has NO superview — nothing has
        // displayed the toolbar. That is what makes this observable: if the
        // inline tray gets built it adopts the button into a glass capsule,
        // and the superview becomes non-nil. Nil here means nobody took it.
        #expect(button.superview == nil, "something already owns the button")

        screen.selectTab(at: 1)

        #expect(button.superview == nil,
                "the tab change built the inline tray, which adopted the button off the toolbar")
        #expect(screen.toolbarItems?.compactMap(\.customView).last === button,
                "the bar item lost its custom view")
    }

    /// …and through several changes: the theft happens once, and everything
    /// after it looks stable while staying broken.
    @Test func theSourceButtonSurvivesRepeatedTabChanges() async {
        guard let screen = await loadedScreen() else { return }
        guard let button = screen.toolbarItems?.compactMap(\.customView).last else { return }

        for index in [1, 2, 0, 1] { screen.selectTab(at: index) }

        #expect(button.superview == nil)
    }
}
