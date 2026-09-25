import CoreModels
import Testing
import UIKit
@testable import Profile

/// The search caret is hidden for the header's morph and always comes back.
///
/// ⚠️ **It used to come back on a guessed 0.32 s timer.** The morph allows
/// touches, so Cancel is tappable in the middle of it: Search → Cancel → Search
/// inside that window saved the first morph's `.clear` as the colour to
/// restore, the second timer restored it, and the caret was gone for the life
/// of the screen. It is restored from the morph's own completion now, and only
/// the newest morph may restore it.
@MainActor
@Suite("Relationship search caret")
struct ProfileRelationshipsSearchCaretTests {
    private struct Screen {
        let controller: ProfileRelationshipsViewController
        let window: UIWindow
    }

    private func open() -> Screen {
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
            repository: CaretStubProvider()
        )
        let controller = ProfileRelationshipsViewController(viewModel: viewModel, imagePipeline: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        return Screen(controller: controller, window: window)
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func caretIsVisible(_ screen: Screen) -> Bool {
        screen.controller.searchField.tintColor != .clear
    }

    @Test func theCaretComesBackOnceTheMorphEnds() async throws {
        let screen = open()
        let resting = screen.controller.searchField.tintColor

        screen.controller.presentSearch()
        #expect(!caretIsVisible(screen), "guard: the morph hides the caret")

        try await settle(until: { caretIsVisible(screen) })
        #expect(screen.controller.searchField.tintColor == resting,
                "the caret did not come back after the morph")
    }

    @Test func aCancelMidMorphDoesNotLoseTheCaret() async throws {
        let screen = open()
        let resting = screen.controller.searchField.tintColor

        screen.controller.presentSearch()
        screen.controller.dismissSearch()
        screen.controller.presentSearch()
        #expect(!caretIsVisible(screen), "guard: the second morph hides the caret")

        // Past every morph and every timer the old code armed — and THEN until
        // the newest morph's completion has run, however late a loaded
        // simulator delivers it. A bare fixed wait here was this suite's own
        // flake: green alone, red inside the full parallel run, where the
        // 0.3 s dissolve's completion can land after 800 ms. The old code
        // still fails it: its last timer left the caret `.clear` for good,
        // so the wait below times out on it.
        try await Task.sleep(for: .milliseconds(800))
        try await settle(until: { caretIsVisible(screen) })

        #expect(screen.controller.searchField.tintColor == resting,
                "the caret was restored to the first morph's .clear")
    }
}

private actor CaretStubProvider: ProfileRelationshipsProviding {
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
