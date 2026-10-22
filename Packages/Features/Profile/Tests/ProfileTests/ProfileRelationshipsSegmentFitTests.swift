import CoreModels
import Testing
import UIKit
@testable import Profile

/// The segment titles keep their counts at every width.
///
/// **This suite used to assert the opposite.** With a `UISegmentedControl` in
/// the navigation bar's title slot, three counted titles did not fit — the slot
/// caps at 258pt — so the screen dropped the counts on narrow devices to avoid
/// truncating "Followers" and "Following" into two identical stubs. Replacing
/// it with `PagedTabBar` removed the constraint that forced that trade: the
/// selector still lives in the title slot, but its segments sit in a scroll
/// view, so titles that out-measure the capsule scroll instead of clipping.
/// The overflow itself is pinned by `PagedTabBarTitleOverflowTests`.
///
/// So the rule these now pin is the simple one: the counts are always there, on
/// every device, whatever they say. Driven through the real view controller so
/// the component and the titles under test are the ones that ship.
@MainActor
@Suite("Relationship segment fit")
struct ProfileRelationshipsSegmentFitTests {
    /// Widths in points, excluding safe-area insets (portrait, no split view).
    private enum DeviceWidth {
        /// iPhone SE / 13 mini — the narrowest the app supports.
        static let narrow: CGFloat = 375
        /// iPhone 17 Pro, the simulator this was verified on.
        static let regular: CGFloat = 402
        /// iPhone 17 Pro Max.
        static let wide: CGFloat = 440
    }

    private func makeController(
        followers: CountEstimate,
        following: CountEstimate,
        width: CGFloat
    ) -> ProfileRelationshipsViewController {
        let viewModel = ProfileRelationshipsViewModel(
            subject: ProfileRelationshipsViewModel.Subject(
                id: ProfileID("subject"),
                handle: "subject",
                visibility: .public,
                viewerFollowsSubject: true,
                isSelf: false,
                followerCount: followers,
                followingCount: following
            ),
            repository: FitStubProvider()
        )
        let controller = ProfileRelationshipsViewController(viewModel: viewModel, imagePipeline: nil)
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func titles(_ controller: ProfileRelationshipsViewController) -> [String] {
        controller.tabBar.currentTitles
    }

    /// A profile pushed from this screen shows the chevron alone, not
    /// "Back" beside it (#727).
    @Test("The screen lends a chevron-only back button")
    func lendsAChevronOnlyBackButton() {
        let controller = makeController(followers: .exact(3), following: .exact(4), width: DeviceWidth.regular)
        #expect(controller.navigationItem.backButtonDisplayMode == .minimal)
    }

    @Test("Small counts fit on the narrowest supported device")
    func smallCountsFitEverywhere() {
        let controller = makeController(
            followers: .exact(35), following: .exact(12), width: DeviceWidth.narrow
        )
        #expect(titles(controller) == ["35 Followers", "12 Following", "Friends"])
    }

    @Test("Counts survive on a regular-width device")
    func moderateCountsFitOnRegularWidth() {
        let controller = makeController(
            followers: .exact(142), following: .exact(89), width: DeviceWidth.regular
        )
        #expect(titles(controller) == ["142 Followers", "89 Following", "Friends"])
    }

    /// The case that forced the old fallback: abbreviated counts on both of
    /// the long nouns, on the narrowest device. The scrolling strip keeps them.
    @Test("Large counts survive on a narrow device")
    func largeCountsSurviveOnNarrowWidth() {
        let controller = makeController(
            followers: .exact(12_400), following: .atLeast(200), width: DeviceWidth.narrow
        )
        #expect(titles(controller) == ["12.4K Followers", "200+ Following", "Friends"])
    }

    /// Whatever the titles end up being, no segment may be blank and there
    /// must be three of them — the failure this whole rule guards against is a
    /// segment the viewer cannot read.
    @Test(
        "Every device width shows three legible segments",
        arguments: [DeviceWidth.narrow, DeviceWidth.regular, DeviceWidth.wide]
    )
    func alwaysThreeLegibleSegments(width: CGFloat) {
        let controller = makeController(
            followers: .exact(1_200_000), following: .exact(999_999), width: width
        )
        let rendered = titles(controller)
        #expect(rendered.count == 3)
        #expect(rendered.allSatisfy { !$0.isEmpty })
        // No ellipsis anywhere: the whole point of the scrolling strip.
        #expect(rendered.allSatisfy { !$0.contains("…") })
        #expect(rendered.last?.hasSuffix("Friends") == true)
    }

    /// Width no longer changes what the segments say — the property the
    /// rewrite bought, stated as an invariant so a future host that re-parents
    /// the bar into a bounded slot fails here rather than in a screenshot.
    @Test("The titles do not depend on the device width")
    func titlesAreWidthIndependent() {
        let rendered = [DeviceWidth.narrow, DeviceWidth.regular, DeviceWidth.wide].map { width in
            titles(makeController(
                followers: .exact(12_400), following: .atLeast(200), width: width
            ))
        }
        #expect(Set(rendered.map { $0.joined(separator: "|") }).count == 1)
        #expect(rendered[0] == ["12.4K Followers", "200+ Following", "Friends"])
    }
}

/// Answers every page with nothing: these tests are about the navigation bar,
/// and rows would only add scheduling to them.
private actor FitStubProvider: ProfileRelationshipsProviding {
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

/// Tab bar ↔ pager, in both directions.
///
/// ⚠️ **The tap half cannot be verified in the simulator.** The bar sits in the
/// top band of the screen, which does not receive injected `CGEvent` touches —
/// a harness limitation, not an app one. A real swipe *was* verified there
/// (the lens tracks the finger frame by frame); the tap is pinned here instead,
/// through the same `.valueChanged` a finger raises.
@MainActor
@Suite("Relationship tab sync")
struct ProfileRelationshipsTabSyncTests {
    private func makeController() -> ProfileRelationshipsViewController {
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
            repository: SyncStubProvider()
        )
        let controller = ProfileRelationshipsViewController(viewModel: viewModel, imagePipeline: nil)
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        return controller
    }

    @Test("Tapping a tab pages to it")
    func tapPagesToTab() {
        let controller = makeController()

        controller.tabBar.debugSimulateTap(at: 2)

        #expect(controller.pager.activeIndex == 2)
    }

    @Test("A settled page selects its tab")
    func settledPageSelectsTab() {
        let controller = makeController()

        controller.pager.setActivePage(1, animated: false)

        #expect(controller.tabBar.selectedIndex == 1)
    }

    /// The lens is driven by fractional progress, not by the settle — this is
    /// what makes it follow a finger instead of snapping when it lifts.
    @Test("A part-way drag moves the lens without changing the page")
    func partialDragMovesLensOnly() {
        let controller = makeController()
        let pager = controller.pager.pagingScrollView

        pager.contentOffset.x = pager.bounds.width * 0.4
        pager.delegate?.scrollViewDidScroll?(pager)

        #expect(controller.pager.activeIndex == 0)
        #expect(controller.tabBar.selectedIndex == 0)
    }

    /// ⚠️ The pager wears the titled header's soft blur and the lists nested in
    /// it stay clear (#1591): UIKit draws no edge effect for a list inside the
    /// pager's scroll view.
    @Test("The pager wears the header's blur, the lists none")
    func everyListFadesUnderTheHeader() {
        let controller = makeController()
        let paging = controller.pager.pagingScrollView
        func lists() -> [UICollectionView] {
            var found: [UICollectionView] = []
            func collect(_ view: UIView) {
                if let list = view as? UICollectionView { found.append(list) }
                view.subviews.forEach(collect)
            }
            collect(paging)
            return found
        }

        // ⚠️ ONE list at construction, not three: the pager makes a page when
        // it is about to show it (charter P3), so the push costs the opening
        // list alone. Paging to the others makes them.
        #expect(lists().count == 1, "only the opening list exists before anyone pages")
        controller.pager.setActivePage(1, animated: false)
        controller.pager.setActivePage(2, animated: false)

        let all = lists()
        #expect(all.count == 3, "Followers, Following and Friends")
        // A titled header (#1591): the soft blur over the bar is the PAGER's —
        // UIKit drew none for the lists nested in it (the owner, 2026-10-22,
        // filmed) — and the lists stay clear, or two bands would stack.
        #expect(!paging.topEdgeEffect.isHidden && paging.topEdgeEffect.style == .soft)
        #expect(all.allSatisfy { $0.topEdgeEffect.isHidden })
    }
}

private actor SyncStubProvider: ProfileRelationshipsProviding {
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
