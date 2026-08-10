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
    /// navigation bar carries nothing.
    @Test func atRestOnlyTheInlineSelectorShows() async {
        guard let screen = await loadedScreen() else { return }
        let state = screen.debugSelectorState
        #expect(state.inline.hidden == false)
        #expect(state.inline.alpha == 1)
        #expect(state.docked.hidden == true)
    }

    /// ⚠️ **The resting selector is HIDDEN, not merely transparent — and this
    /// is a shipped bug, not a hypothetical.** A navigation bar owns its title
    /// view's alpha: it fades the slot through every push and pop and sets it
    /// back to 1 on the way out. A docked bar parked at `alpha = 0` therefore
    /// came back at FULL STRENGTH, sitting in the chrome above an un-scrolled
    /// profile with the banner and avatar still on screen. `isHidden` is not a
    /// property UIKit touches there.
    ///
    /// Asserted as "UIKit can set alpha to whatever it likes and the bar stays
    /// gone", which is the property that actually matters.
    @Test func theRestingSelectorSurvivesTheBarRewritingItsAlpha() async {
        guard let screen = await loadedScreen() else { return }
        screen.debugSetBarDocked(false)
        // Exactly what a completed push or pop leaves behind.
        screen.navigationItem.titleView?.alpha = 1
        #expect(screen.debugSelectorState.docked.hidden == true)
    }

    /// Docked, the two swap: the navigation bar carries the selector and the
    /// column's copy is gone.
    @Test func dockedOnlyTheNavigationBarSelectorShows() async {
        guard let screen = await loadedScreen() else { return }
        screen.debugSetBarDocked(true)
        let state = screen.debugSelectorState
        #expect(state.docked.hidden == false)
        #expect(state.docked.alpha == 1)
        #expect(state.inline.hidden == true)
    }

    /// And back again — the hand-over is reversible, which a one-way setup
    /// that only ever hid things would fail.
    @Test func undockingBringsTheInlineSelectorBack() async {
        guard let screen = await loadedScreen() else { return }
        screen.debugSetBarDocked(true)
        screen.debugSetBarDocked(false)
        let state = screen.debugSelectorState
        #expect(state.inline.hidden == false)
        #expect(state.inline.alpha == 1)
        #expect(state.docked.hidden == true)
    }

    // MARK: - Keeping them in step

    /// Both start on the same tab, so the first hand-over has nothing to
    /// reconcile.
    @Test func bothSelectorsStartOnTheSameTab() async {
        guard let screen = await loadedScreen() else { return }
        let indices = screen.debugSelectedIndices
        #expect(indices.allSatisfy { $0 == indices.first })
    }

    /// ⚠️ A tap on either one carries to the other. This is the cost of having
    /// two: the invisible one is what the viewer sees NEXT, so a selection that
    /// reached only the visible bar would render as the tab silently changing
    /// back the moment the header docked.
    @Test(arguments: [false, true])
    func choosingOnEitherSelectorReachesBoth(onDocked: Bool) async {
        guard let screen = await loadedScreen() else { return }
        screen.debugSelect(2, onDocked: onDocked)
        #expect(screen.debugSelectedIndices == [2, 2])
    }

    /// ⚠️ And mirroring terminates. `select` announces itself exactly as a tap
    /// does — there is deliberately no silent variant — so carrying a choice to
    /// the other bar re-enters the handler that started it. Without the guard
    /// this recurses until the stack gives out; the test that catches it is
    /// simply one that returns.
    @Test func mirroringDoesNotFeedItself() async {
        guard let screen = await loadedScreen() else { return }
        screen.debugSelect(1, onDocked: false)
        screen.debugSelect(2, onDocked: true)
        screen.debugSelect(0, onDocked: false)
        #expect(screen.debugSelectedIndices == [0, 0])
    }

    // MARK: - The toolbar button survives a tab change

    /// Under the toolbar placement the source menu button IS the bar item's
    /// `customView`. The INLINE tray — the other placement's home for that same
    /// button — wraps it in a glass capsule and adopts it as a subview, so
    /// merely BUILDING the tray takes it off the toolbar. It is a `lazy var`,
    /// so touching it is building it, and `adoptTab` touched it on every tab
    /// change whatever the placement.
    ///
    /// What the viewer saw: a full-width blank capsule at the bottom of the
    /// screen, and only after changing tab — which is why the first tab always
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
