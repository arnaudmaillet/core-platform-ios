import CoreModels
import CoreNavigation
import Testing
import UIKit
@testable import Profile

/// **The relations screen pops with the native back swipe (#1300).** Pushed
/// from a profile's counters, it follows `PagedScreenDismissalPolicy`: on
/// Followers (the first tab, nothing to its left) a rightward drag started
/// anywhere goes back; on Following and Friends it pages back, and only the
/// edge strip — the other recogniser's, ungated — goes back.
@MainActor
@Suite("Relationship back swipe")
struct ProfileRelationshipsBackSwipeTests {
    private func makeScreen() -> ProfileRelationshipsViewController {
        let viewModel = ProfileRelationshipsViewModel(
            subject: ProfileRelationshipsViewModel.Subject(
                id: ProfileID("subject"),
                handle: "subject",
                visibility: .public,
                viewerFollowsSubject: true,
                isSelf: false,
                followerCount: .exact(35),
                followingCount: .exact(12)
            ),
            repository: BackSwipeStubProvider()
        )
        return ProfileRelationshipsViewController(viewModel: viewModel, imagePipeline: nil)
    }

    /// Mid-screen on Followers: the swipe may begin. On Following and Friends
    /// it may not, wherever the drag starts.
    @Test func theFirstTabGoesBackFromAnywhere() {
        let screen = makeScreen()
        let stack = UINavigationController(rootViewController: UIViewController())
        stack.pushViewController(screen, animated: false)
        screen.loadViewIfNeeded()
        let gate: any ContentPopGating = screen

        #expect(screen.pager.activeIndex == 0, "precondition: Followers is the first tab")
        #expect(gate.allowsContentPop(beginningAt: CGPoint(x: 200, y: 400), in: screen.view))
        #expect(gate.allowsContentPop(beginningAt: CGPoint(x: 4, y: 400), in: screen.view))

        for tab in 1..<3 {
            screen.pager.setActivePage(tab, animated: false)
            #expect(!gate.allowsContentPop(beginningAt: CGPoint(x: 200, y: 400), in: screen.view),
                    "tab \(tab) went back instead of paging")
            #expect(!gate.allowsContentPop(beginningAt: CGPoint(x: 4, y: 400), in: screen.view),
                    "tab \(tab): the edge is the edge recogniser's, not this one's")
        }
    }

    /// A stack's root has nothing to go back to.
    @Test func aRootScreenNeverGoesBack() {
        let screen = makeScreen()
        _ = UINavigationController(rootViewController: screen)
        screen.loadViewIfNeeded()
        let gate: any ContentPopGating = screen
        #expect(!gate.allowsContentPop(beginningAt: CGPoint(x: 200, y: 400), in: screen.view))
    }
}

private actor BackSwipeStubProvider: ProfileRelationshipsProviding {
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
