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

        list.presentSearch()
        list.dismissSearch()

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

        list.presentSearch()
        #expect(tabs.requests == [true], "the search did not hide the bar it owns")

        list.dismissSearch()
        #expect(tabs.requests == [true, false], "Cancel did not give back the bar the list owns")
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
