import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// EXPERIMENTAL (#1681, `ForYouFullScreenExperiment`): the full-screen post
/// feed as the For You tab's root — the author pill in the top bar, the
/// shell's bell leading, no toolbar, save and repost upright in the action
/// column. Off, the feed is exactly what it was (the other suites).
@MainActor
struct SnapForYouRootTests {
    private func feed(root: Bool) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: RootEmptyProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.isForYouRoot = root
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.seedProjection([SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1"))])
        controller.view.layoutIfNeeded()
        return controller
    }

    // MARK: - The bars

    /// No toolbar on the root: the tab bar holds the bottom; the pill is the
    /// top bar's, trailing.
    @Test func theRootHasNoToolbarAndThePillInTheTopBar() {
        let root = feed(root: true)
        root.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(root.toolbarItems?.isEmpty ?? true, "the root wears a toolbar: \(root.toolbarItems ?? [])")
        let trailing = root.navigationItem.rightBarButtonItems ?? []
        #expect(trailing.contains { $0.customView is SnapAuthorIdentityView }, "the pill is not in the top bar")
        #expect(trailing.allSatisfy { $0.identifier != nil || ($0.customView == nil && $0.accessibilityLabel == nil) },
                "an item without an identity (#1679)")
    }

    /// Off the root, the feed keeps its toolbar and the pill there.
    @Test func offTheRootTheToolbarAndPillAreAsBefore() {
        let pushed = feed(root: false)
        pushed.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(pushed.toolbarItems?.first?.customView is SnapAuthorIdentityView)
        #expect(!(pushed.navigationItem.rightBarButtonItems ?? []).contains { $0.customView is SnapAuthorIdentityView })
    }

    /// The shell's bell leads while nothing else holds the edge; the ✕ takes
    /// it while a media post's comments are open, and the pill stays.
    @Test func theBellLeadsAndTheExitTakesItsPlaceInTheComments() {
        let root = feed(root: true)
        let bell = BarItems.icon(id: BarItems.SharedID.notificationsBell, image: nil, label: "Notifications") {}
        root.setLeadingAccessoryItem(bell)
        #expect(root.navigationItem.leftBarButtonItems?.first === bell)

        root.setEngagedChrome(true, hasMedia: true, animated: false)
        #expect(root.navigationItem.leftBarButtonItems?.first?.accessibilityLabel == "Close comments")
        #expect((root.navigationItem.rightBarButtonItems ?? []).contains { $0.customView is SnapAuthorIdentityView },
                "the pill left the bar with the comments open")

        root.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(root.navigationItem.leftBarButtonItems?.first === bell)
    }

    // MARK: - The column

    /// Save and repost stand upright between the like pill and the sound
    /// bubble: the capsule `gap` over the sound, the pill `gap` over the
    /// capsule — the pill risen by exactly the capsule's room.
    @Test func theCapsuleStandsBetweenTheLikePillAndTheSound() {
        let before = SnapActionColumnLayoutTests.chrome()
        let pillBefore = before.debugBoostButton.frame

        let chrome = SnapActionColumnLayoutTests.chrome()
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
        chrome.showsPostActions = true
        chrome.layoutIfNeeded()
        let like = chrome.debugBoostButton.frame
        let capsule = chrome.postActions.frame
        let sound = chrome.debugSoundBubble.frame
        #expect(!chrome.postActions.isHidden, "no capsule on a media page")
        #expect(abs(capsule.height - SnapPostActionsCapsule.height) < 0.5)
        #expect(abs(sound.minY - capsule.maxY - SnapActionColumn.gap) < 0.5, "the capsule is not gap over the sound")
        #expect(abs(capsule.minY - like.maxY - SnapActionColumn.gap) < 0.5, "the like pill is not gap over the capsule")
        #expect(abs(like.height - pillBefore.height) < 0.5, "the like pill changed height")
        #expect(abs(pillBefore.minY - like.minY - SnapPostActionsCapsule.columnExtent) < 0.5,
                "the pill did not rise by the capsule's room")
    }

    /// Off, nothing moves and no capsule shows.
    @Test func withoutTheExperimentTheColumnIsUnchanged() {
        let chrome = SnapActionColumnLayoutTests.chrome()
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
        chrome.layoutIfNeeded()
        #expect(chrome.postActions.isHidden)
    }

    /// The capsule's star follows the saved state, and its tap asks the screen.
    @Test func theCapsuleSavesAndDrawsTheStar() {
        let capsule = SnapPostActionsCapsule()
        var saves = 0
        capsule.onSave = { saves += 1 }
        capsule.saveButton.sendActions(for: .primaryActionTriggered)
        #expect(saves == 1)
        capsule.setSaved(true)
        #expect(capsule.saveButton.accessibilityLabel == "Saved")
        capsule.setActionsEnabled(false)
        #expect(!capsule.saveButton.isEnabled && !capsule.repostButton.isEnabled)
    }

    // MARK: - The composer

    /// The composer's column holds the capsule too: its resting height grows
    /// by exactly the capsule's room (a text page draws it there).
    @Test func theComposerColumnMakesRoomForTheCapsule() {
        let plain = CommentsInputBar.restingHeight(for: .large)
        let withActions = CommentsInputBar.restingHeight(for: .large, postActions: true)
        #expect(abs(withActions - plain - SnapPostActionsCapsule.columnExtent) < 0.5)
        #expect(CommentsInputBar.restingHeight(for: .large, showsStake: false, postActions: true)
            == CommentsInputBar.restingHeight(for: .large, showsStake: false),
                "a column with no stake (a conversation) took the capsule")
    }
}

private final class RootEmptyProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(id: id, authorID: ProfileID("p"), caption: "", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }
}
