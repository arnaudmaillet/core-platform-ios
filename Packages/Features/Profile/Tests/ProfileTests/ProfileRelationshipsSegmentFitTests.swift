import CoreModels
import Testing
import UIKit
@testable import Profile

/// Whether the three segment titles fit the navigation bar.
///
/// Counts came back to the segments ("1.2K Followers"), and three counted
/// titles are much wider than the two this control was built for. When they do
/// not fit, a `UISegmentedControl` truncates — and the strings it eats into are
/// "Followers" and "Following", producing "12.4K Follow…" and "200+ Follow…",
/// which are indistinguishable. So the screen drops the counts instead, and
/// these tests pin both halves of that rule.
///
/// Driven through the real view controller at real device widths rather than a
/// rebuilt control, so the font, the padding and the width budget under test
/// are the ones that actually ship.
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
        (0..<controller.segmentedControl.numberOfSegments)
            .compactMap { controller.segmentedControl.titleForSegment(at: $0) }
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

    /// The case the fallback exists for: abbreviated counts on both of the
    /// long nouns, on the narrowest device.
    @Test("Large counts on a narrow device fall back to bare nouns")
    func largeCountsDegradeOnNarrowWidth() {
        let controller = makeController(
            followers: .exact(12_400), following: .atLeast(200), width: DeviceWidth.narrow
        )
        #expect(titles(controller) == ["Followers", "Following", "Friends"])
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
        #expect(rendered.last?.hasSuffix("Friends") == true)
    }

    /// A wider device should not throw information away — the fallback is for
    /// when the counts do not fit, not a blanket retreat.
    @Test("A wide device keeps the counts that a narrow one drops")
    func wideDeviceKeepsCountsNarrowDrops() {
        let narrow = makeController(
            followers: .exact(12_400), following: .atLeast(200), width: DeviceWidth.narrow
        )
        let wide = makeController(
            followers: .exact(12_400), following: .atLeast(200), width: DeviceWidth.wide
        )
        #expect(titles(narrow).first == "Followers")
        #expect(titles(wide).first == "12.4K Followers")
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
