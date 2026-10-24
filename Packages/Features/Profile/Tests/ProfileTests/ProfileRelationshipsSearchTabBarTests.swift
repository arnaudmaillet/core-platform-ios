import CoreModels
import Testing
import UIKit
@testable import Profile

/// The relationships search touches the tab bar only where the screen owns it
/// (#782).
///
/// ⚠️ **A PUSHED LIST DOES NOT OWN THE BAR.** The screen is pushed with
/// `hidesBottomBarWhenPushed`, so the bar is UIKit's there. The search used to
/// hide it on Search and show it on Cancel unconditionally: the hide did
/// nothing, and the show slid the tab bar in over the list and its toolbar,
/// with nothing to take it away again after the pop. A list at the root of a
/// tab's stack still hides the bar for the search and gives it back after.
///
/// The search is the system's (`UISearchController`, #1679): its delegate's
/// `willPresent` / `willDismiss` are what ask, and are called here as UIKit
/// calls them — a windowless test host never runs the presentation itself.
///
/// What is asserted is what the screen ASKS its tab bar controller for, read
/// through a recording subclass. The bar's visible state cannot tell the two
/// apart: an explicit hide and show leave `isTabBarHidden` where it started,
/// and UIKit's flag hides the bar either way until the Cancel's show lands.
@MainActor
@Suite("Relationship search and the tab bar")
struct ProfileRelationshipsSearchTabBarTests {
    /// Records every `setTabBarHidden` it is sent, in order: true for a hide,
    /// false for a show.
    private final class RecordingTabBarController: UITabBarController {
        private(set) var requests: [Bool] = []

        override func setTabBarHidden(_ hidden: Bool, animated: Bool) {
            requests.append(hidden)
            super.setTabBarHidden(hidden, animated: animated)
        }
    }

    private func makeList(isSelf: Bool) -> ProfileRelationshipsViewController {
        let viewModel = ProfileRelationshipsViewModel(
            subject: ProfileRelationshipsViewModel.Subject(
                id: ProfileID(isSelf ? "viewer" : "subject"),
                handle: isSelf ? "viewer" : "subject",
                visibility: .public,
                viewerFollowsSubject: !isSelf,
                isSelf: isSelf,
                followerCount: .exact(35),
                followingCount: .exact(12)
            ),
            repository: TabBarStubProvider()
        )
        return ProfileRelationshipsViewController(viewModel: viewModel, imagePipeline: nil)
    }

    /// A tab bar controller with one tab whose stack is `screens`, root first.
    /// No window: the stack, its flag and the requests are all the test reads,
    /// and nothing is left on screen for the next suite.
    private func makeTabs(stack screens: [UIViewController]) -> RecordingTabBarController {
        let navigation = UINavigationController()
        navigation.setViewControllers(screens, animated: false)
        let tabs = RecordingTabBarController()
        tabs.viewControllers = [navigation]
        tabs.loadViewIfNeeded()
        return tabs
    }

    @Test func cancellingSearchOnAPushedListLeavesTheTabBarHidden() throws {
        let list = makeList(isSelf: false)
        let tabs = makeTabs(stack: [UIViewController(), list])
        list.loadViewIfNeeded()
        try #require(list.tabBarController === tabs, "guard: the list is not inside the tab bar controller")
        try #require(list.hidesBottomBarWhenPushed, "guard: the list no longer hides the bar when pushed")

        list.willPresentSearchController(list.searchController)
        list.willDismissSearchController(list.searchController)

        #expect(!tabs.requests.contains(false),
                "Cancel showed the tab bar over a pushed list: \(tabs.requests)")
        // ⚠️ No hide either (#769): under the flag every close asks
        // `showsAppTabBar`, which is false there, so an explicit hide is
        // never taken back and outlives the pops.
        #expect(tabs.requests.isEmpty, "the search sent the bar requests it does not own: \(tabs.requests)")
    }

    @Test func aListAtTheRootOfItsTabStillHidesTheBarForSearchAndGivesItBack() throws {
        let list = makeList(isSelf: true)
        let tabs = makeTabs(stack: [list])
        list.loadViewIfNeeded()
        try #require(list.tabBarController === tabs, "guard: the list is not inside the tab bar controller")

        list.willPresentSearchController(list.searchController)
        #expect(tabs.requests == [true], "the search did not hide the bar it owns")

        list.willDismissSearchController(list.searchController)
        #expect(tabs.requests == [true, false], "Cancel did not give back the bar the list owns")
    }

    /// The magnifier is the system search's `.integratedButton`, placed by
    /// UIKit — no field in the title slot, no hand-made bar dissolve (#1679).
    /// ⚠️ Never the placement item among the bar's items: iOS 26 throws.
    @Test func theMagnifierIsTheSystemSearchBarsItem() throws {
        let list = makeList(isSelf: true)
        list.loadViewIfNeeded()
        #expect(list.navigationItem.searchController === list.searchController)
        #expect(list.navigationItem.preferredSearchBarPlacement == .integratedButton)
        #expect(list.searchController.searchResultsController == nil, "the lists filter in place")
        let trailing = list.navigationItem.rightBarButtonItems ?? []
        #expect(!trailing.contains { $0 === list.navigationItem.searchBarPlacementBarButtonItem })
        #expect(list.navigationItem.titleView == nil, "a field in the title slot")
    }
}

private actor TabBarStubProvider: ProfileRelationshipsProviding {
    let supportsFollowerRemoval = false

    func relationships(
        for profileID: ProfileID,
        direction: RelationshipDirection,
        pageToken: String,
        limit: Int32
    ) async throws -> RelationshipPage {
        RelationshipPage(relations: [], nextPageToken: "")
    }

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func removeFollower(_ profileID: ProfileID) async throws {}
    func invalidateViewerCache() async {}
}
