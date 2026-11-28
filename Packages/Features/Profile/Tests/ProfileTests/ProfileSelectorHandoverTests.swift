import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import PostGrid
import ProfileInterface
import Testing
import UIKit
@testable import Profile
@testable import ProfileData

/// Where a profile's selector is, and what else is in the bar with it.
///
/// ⚠️ **ONE SELECTOR THAT MOVES (#2475, the owner 2026-11-28).** It sits in
/// the header at rest, where the action row stood, and moves into the bar's
/// leading group past the threshold — right after the bell on the tab root,
/// right after the chevron on a pushed profile — and back. Never the tab
/// bar's accessory, never the bottom toolbar (someone else's relationship
/// toolbar is there).
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
        gallery: any ProfileGalleryProviding = StockedGallery(),
        accountRoot: Bool = false
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
            makeGridPage: TestGridPages.factory(), presence: SectionPresenceStore(scope: StorageScope()),
            onLogout: accountRoot ? {} : nil,
            trayPlacement: trayPlacement
        )
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.view.layoutIfNeeded()
        return screen
    }

    /// The screen in a stack in a visible window: pushed over a root, or the
    /// stack's root with the shell's bell.
    private func hosted(
        _ screen: ProfileViewController, pushed: Bool
    ) -> (UINavigationController, UIWindow) {
        let navigation = UINavigationController(rootViewController: pushed ? UIViewController() : screen)
        if pushed { navigation.pushViewController(screen, animated: false) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        return (navigation, window)
    }

    /// ⚠️ AT REST THE SELECTOR IS IN THE HEADER (#2475): in the slot where the
    /// action row stood, drawn on the header's own capsule — no toolbar strip,
    /// no tab accessory, nothing in the bar's leading group but the bell.
    @Test(arguments: [false, true])
    func atRestTheSelectorIsInTheHeader(pushed: Bool) async throws {
        guard let screen = await loadedScreen(
            trayPlacement: pushed ? .navigationToolbar : .aboveBottomSafeArea, accountRoot: !pushed
        ) else { return }
        let bell = UIBarButtonItem(image: UIImage(systemName: "bell"))
        bell.identifier = "shell.notifications-bell"
        if !pushed { screen.setLeadingAccessoryItem(bell) }
        let (_, window) = hosted(screen, pushed: pushed)
        defer { window.isHidden = true }
        #expect(screen.selector.isPlaced && !screen.selector.isInBar)
        #expect(screen.selectorBar.superview === screen.selector.headerSlot, "the strip is not in the header")
        #expect(screen.selectorBar.hosting == .standalone, "the header's strip draws no glass of its own")
        #expect(screen.selector.headerSlot.window != nil, "the header's slot is not on screen")
        #expect(!(screen.toolbarItems ?? []).contains { $0.customView is PagedTabBar }, "a toolbar strip")
        #expect(screen.debugLeadingIDs == (pushed ? [] : ["shell.notifications-bell"]))
    }

    /// ⚠️ PAST THE THRESHOLD THE SELECTOR IS IN THE BAR'S LEADING GROUP, right
    /// after the bell (the tab root) or the chevron (a pushed profile) — the
    /// same strip, the same page selected — and back in the header after.
    /// The chevron stays: `leftItemsSupplementBackButton`.
    @Test(arguments: [false, true])
    func pastTheThresholdTheSelectorMovesIntoTheBarAndBack(pushed: Bool) async throws {
        guard let screen = await loadedScreen(
            trayPlacement: pushed ? .navigationToolbar : .aboveBottomSafeArea, accountRoot: !pushed
        ) else { return }
        let bell = UIBarButtonItem(image: UIImage(systemName: "bell"))
        bell.identifier = "shell.notifications-bell"
        if !pushed { screen.setLeadingAccessoryItem(bell) }
        let (_, window) = hosted(screen, pushed: pushed)
        defer { window.isHidden = true }
        screen.selectTab(at: 1)

        screen.debugSetPastThreshold(true)
        #expect(screen.selector.isInBar)
        let leading = screen.navigationItem.leftBarButtonItems ?? []
        let strip = try #require(leading.last?.customView as? PagedTabBar, "the selector is not the last leading item")
        #expect(strip === screen.selectorBar, "a second strip")
        #expect(leading.last?.identifier == ProfileNavigationBarComposer.selectorItemID)
        #expect(screen.debugLeadingIDs == (pushed
            ? [ProfileNavigationBarComposer.selectorItemID]
            : ["shell.notifications-bell", ProfileNavigationBarComposer.selectorItemID]),
            "not right after the bell or the chevron: \(screen.debugLeadingIDs)")
        #expect(strip.hosting == .platter, "the bar's strip draws a glass inside the platter")
        #expect(strip.selectedIndex == 1, "the page changed with the hand-off")
        #expect(!screen.selector.headerSlot.hostsStrip, "the strip is in two places")
        #expect(screen.navigationItem.leftItemsSupplementBackButton, "the selector replaced the back button")
        #expect(screen.navigationItem.hidesBackButton == false)

        screen.debugSetPastThreshold(false)
        #expect(!screen.selector.isInBar)
        #expect(screen.selectorBar.superview === screen.selector.headerSlot, "the strip did not come back")
        #expect(screen.selectorBar.selectedIndex == 1)
        #expect(screen.debugLeadingIDs == (pushed ? [] : ["shell.notifications-bell"]))
    }

    /// ⚠️ NOTHING ELSE IN A PROFILE'S BAR (#2475 §1): no title, no balance, no
    /// day, no Follow — at rest or past the threshold, own or someone else's.
    @Test(arguments: [false, true])
    func aProfilesBarCarriesNoTitleBalanceDayOrFollow(pushed: Bool) async throws {
        guard let screen = await loadedScreen(
            source: pushed ? .profile(ProfileID("prof-2")) : .currentUser,
            trayPlacement: pushed ? .navigationToolbar : .aboveBottomSafeArea
        ) else { return }
        let balance = UIBarButtonItem(title: "250")
        balance.accessibilityLabel = "Balance"
        screen.setTrailingAccessoryItem(balance)
        let (_, window) = hosted(screen, pushed: pushed)
        defer { window.isHidden = true }
        for past in [false, true] {
            screen.debugSetPastThreshold(past)
            let all = (screen.navigationItem.leftBarButtonItems ?? []) + (screen.navigationItem.rightBarButtonItems ?? [])
            #expect(screen.navigationItem.title == nil && screen.navigationItem.titleView == nil, "a title")
            #expect(!all.contains { $0 === balance || $0.accessibilityLabel == "Balance" }, "a balance")
            #expect(!all.contains { ($0.identifier ?? "").contains("section") || ($0.identifier ?? "").contains("day") },
                    "a day item")
            #expect(!all.contains { $0.title == "Follow" || $0.title == "Requested"
                || ($0.identifier ?? "").contains("follow") }, "a Follow in the bar")
        }
    }

    /// ⚠️ **A TAB THAT ARRIVES LATE (#742) PUTS THE SELECTOR IN THE HEADER**,
    /// once there are two pages — never a tab bar accessory, covered or not.
    @Test func aTabArrivingLatePlacesTheSelectorInTheHeader() async throws {
        guard let screen = await loadedScreen(trayPlacement: .aboveBottomSafeArea, gallery: EmptyGallery())
        else { return }
        let tabs = UITabBarController()
        let navigation = UINavigationController(rootViewController: screen)
        tabs.viewControllers = [navigation]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        #expect(!screen.selector.isPlaced, "one tab is no selector")
        #expect(!screen.heroHeader.showsActionTray, "an empty selector row with one tab")

        var snapshot = try #require(screen.viewModel.publishedGallery)
        snapshot.reposts = .content([GalleryPost(
            id: PostID("r1"), kind: .photo, isRepost: true, thumbnailURL: nil, caption: "r1", publishedAtMS: 1
        )])
        screen.viewModel.onGalleryChange?(snapshot)
        #expect(screen.selector.isPlaced, "the second tab built no selector")
        #expect(screen.heroHeader.showsActionTray && screen.selector.headerSlot.hostsStrip)
        #expect(tabs.bottomAccessory == nil, "a tab bar accessory")
    }

    /// ⚠️ THE SELECTED PAGE STAYS IN VIEW (#2361's rule, #2475): in a bar too
    /// narrow for every title, after `setActivePage`, the selected title's
    /// pill is inside the strip's viewport.
    @Test func theSelectedPageStaysInViewAfterSetActivePage() async throws {
        guard let screen = await loadedScreen(trayPlacement: .navigationToolbar) else { return }
        let (_, window) = hosted(screen, pushed: true)
        defer { window.isHidden = true }
        screen.debugSetPastThreshold(true)
        let strip = screen.selectorBar
        for index in screen.debugTabTitles.indices.reversed() {
            screen.selectTab(at: index)
            window.layoutIfNeeded()
            strip.layoutIfNeeded()
            let pill = strip.debugPillInViewport
            #expect(strip.selectedIndex == index)
            #expect(pill.minX >= -0.5 && pill.maxX <= strip.debugViewportWidth + 0.5,
                    "page \(index)'s pill \(pill) is out of the \(strip.debugViewportWidth)pt viewport")
        }
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

    /// ⚠️ **POSTS · REPOSTS · TAGGED IN THE TAB ROOT'S SELECTOR (#772)**, each
    /// with something in it — Saved and Liked join only once they hold
    /// something (#742).
    @Test func yourOwnProfileListsRepostsAndTaggedInTheSelector() async {
        guard let screen = await loadedScreen(trayPlacement: .aboveBottomSafeArea) else { return }
        #expect(screen.debugTabTitles == ["Posts", "Reposts", "Tagged"])
        #expect(screen.debugSelectorTitles == ["Posts", "Reposts", "Tagged"])
        #expect(screen.debugPageCount == 3)
        #expect(screen.selector.isPlaced, "no selector")
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

    /// ⚠️ POSTS · REPOSTS · TAGGED IN THE SELECTOR, NO FILTER UP TOP (#696).
    /// Someone else's sources are pages now, switched by the selector or a
    /// swipe, so the bar's source filter is gone. It opens on Posts.
    @Test func someoneElsesProfileHasPostsRepostsTaggedInTheSelector() async {
        guard let screen = await loadedScreen(source: .profile(ProfileID("prof-2"))) else { return }
        #expect(screen.selector.isPlaced, "no selector")
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
        #expect(!screen.selector.isPlaced, "a selector with one tab")
        #expect(!screen.heroHeader.showsActionTray, "an empty selector row with one tab")
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
        #expect(screen.selector.isPlaced)
    }

    /// Posts alone is no selector, on a pushed profile as on the tab root.
    @Test(arguments: [ProfileTrayPlacement.navigationToolbar, .aboveBottomSafeArea])
    func postsAloneIsNoSelector(placement: ProfileTrayPlacement) async {
        guard let screen = await loadedScreen(
            source: .profile(ProfileID("prof-2")), trayPlacement: placement,
            gallery: StockedGallery(reposts: false, tagged: false)
        ) else { return }
        #expect(screen.debugTabTitles == ["Posts"])
        #expect(screen.debugPageCount == 1)
        #expect(!screen.selector.isPlaced, "a selector with one tab")
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
