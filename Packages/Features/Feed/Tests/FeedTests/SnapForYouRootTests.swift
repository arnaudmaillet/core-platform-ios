import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// (#1681): the full-screen post
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

    /// No toolbar on the root at rest: the tab bar holds the bottom. And no
    /// pill in the top bar either (#1699): the author is inside the page.
    @Test func theRootHasNoToolbarAndNoPillInTheTopBar() {
        let root = feed(root: true)
        root.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(root.toolbarItems?.isEmpty ?? true, "the root wears a toolbar: \(root.toolbarItems ?? [])")
        let trailing = root.navigationItem.rightBarButtonItems ?? []
        #expect(!trailing.contains { $0.customView is SnapAuthorIdentityView }, "a pill in the root's top bar")
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
        #expect(!(root.navigationItem.rightBarButtonItems ?? []).contains { $0.customView is SnapAuthorIdentityView })

        root.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(root.navigationItem.leftBarButtonItems?.first === bell)
    }

    // MARK: - The author inside the page (#1699)

    /// The page shows its author between the stream and the caption, with no
    /// glass — the stream stands on it; off the root it does not show.
    @Test func theAuthorRowStandsBetweenTheStreamAndTheCaption() {
        let chrome = SnapActionColumnLayoutTests.chrome()
        let model = SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1"))
        chrome.configure(with: model)
        chrome.showsAuthorRow = true
        chrome.setAuthorRow(model, badge: .follow, pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        chrome.layoutIfNeeded()
        #expect(!chrome.authorRow.isHidden)
        #expect(!(chrome.authorRow.subviews.contains { $0 is UIVisualEffectView }), "the author row draws glass")
        #expect(chrome.interactionRoots.contains { $0 === chrome.authorRow }, "a tap on the author would toggle playback")

        let plain = SnapActionColumnLayoutTests.chrome()
        plain.configure(with: model)
        plain.layoutIfNeeded()
        #expect(plain.authorRow.isHidden, "the author row shows off the root")
    }

    // MARK: - The comments keep the tab bar (#1699)

    /// Comments open on the root: the tab bar stays, and no toolbar comes up
    /// (a placeholder toolbar in its place was tried and dropped).
    @Test func theCommentsKeepTheTabBar() async throws {
        let root = feed(root: true)
        let nav = UINavigationController(rootViewController: root)
        let tabs = UITabBarController()
        tabs.viewControllers = [nav]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<100 where root.view.window == nil { try await Task.sleep(for: .milliseconds(10)) }

        root.setEngagedChrome(true, hasMedia: true, animated: false)
        #expect(!tabs.isTabBarHidden, "the comments hid the tab bar")
        #expect(nav.isToolbarHidden, "a toolbar came up with the comments")

        root.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(!tabs.isTabBarHidden)
    }

    // MARK: - Set aside by the notifications drawer (#1703)

    /// The drawer slides the shell aside with the feed still on screen: its
    /// lifecycle stops counting it as watched (nothing plays), and counts it
    /// again when the drawer closes.
    @Test func theDrawerSetsTheFeedAside() async throws {
        let root = feed(root: true)
        let nav = UINavigationController(rootViewController: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = nav
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<200 where !root.debugIsWatchedByLifecycle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(root.debugIsWatchedByLifecycle, "the feed on screen is not watched")

        root.setSetAside(true)
        #expect(!root.debugIsWatchedByLifecycle, "the feed plays on behind the drawer")
        root.setSetAside(false)
        #expect(root.debugIsWatchedByLifecycle, "the feed did not come back")
    }

    // MARK: - The danmaku replaces the stream (#1699)

    private static func streams(reactions: Int) -> FeedViewModel.CommentStreams {
        FeedViewModel.CommentStreams(
            reactions: (0..<reactions).map { TickerCommentModel(id: "r\($0)", text: "fire \($0)") },
            subtitles: [SubtitleCue(id: "s0", text: "A whole sentence worth reading.")],
            commentCount: reactions + 1
        )
    }

    private static func streamZone(of chrome: SnapChromeView) throws -> SnapSubtitleView {
        try #require(chrome.subviews.lazy.compactMap { $0 as? SnapSubtitleView }.first)
    }

    /// On the root, a danmaku with bubbles takes the stream's seat on the
    /// author row and the stream stays down; with none, the stream speaks.
    @Test func aDanmakuReplacesTheStreamOnTheRoot() throws {
        let chrome = SnapActionColumnLayoutTests.chrome()
        let model = SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1"))
        chrome.configure(with: model)
        chrome.showsAuthorRow = true
        chrome.setAuthorRow(model, badge: .follow, pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        let stream = try Self.streamZone(of: chrome)

        chrome.updateCommentStreams(Self.streams(reactions: 8))
        chrome.setNeedsLayout()
        chrome.layoutIfNeeded()
        #expect(stream.isHidden, "the stream shows under a running danmaku")
        #expect(abs(chrome.debugTickerFrame.maxY - (chrome.authorRow.frame.minY - Spacing.md)) < 0.5,
                "the danmaku is not in the stream's seat")

        chrome.updateCommentStreams(Self.streams(reactions: 0))
        chrome.setNeedsLayout()
        chrome.layoutIfNeeded()
        #expect(!stream.isHidden, "no danmaku, and the stream stayed down")
        #expect(abs(chrome.debugStreamFrame.maxY - (chrome.authorRow.frame.minY - Spacing.md)) < 0.5)
    }

    /// Off the root, the danmaku rides above the stream as it always has.
    @Test func offTheRootTheDanmakuRidesAboveTheStream() throws {
        let chrome = SnapActionColumnLayoutTests.chrome()
        chrome.configure(with: SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1")))
        let stream = try Self.streamZone(of: chrome)
        chrome.updateCommentStreams(Self.streams(reactions: 8))
        chrome.layoutIfNeeded()
        #expect(!stream.isHidden)
        #expect(chrome.debugTickerFrame.maxY <= chrome.debugStreamFrame.minY)
    }

    // MARK: - The bottom block (#1716)

    /// Shots wears every feed's bottom layout — the strip left of the sound
    /// cover — and every feed stands a breath over its bottom bar (Shots 12 pt,
    /// the rest 6, #1716/#1722); with no strip, Shots' caption comes down to
    /// the cover's line.
    @Test func everyFeedStandsOneBreathOverItsBar() {
        func laidOut(pages: Int, shots: Bool) -> SnapChromeView {
            let chrome = SnapActionColumnLayoutTests.chrome()
            chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
            chrome.showsPostActions = shots
            chrome.sitsOverTabBar = shots
            chrome.setMediaPageCount(pages, current: 0)
            chrome.setNeedsLayout()
            chrome.layoutIfNeeded()
            return chrome
        }
        func frame(_ view: UIView, in chrome: SnapChromeView) -> CGRect { view.convert(view.bounds, to: chrome) }
        let shots = laidOut(pages: 9, shots: true)
        let plain = laidOut(pages: 9, shots: false)
        let bar = frame(shots.debugPageBar, in: shots)
        let sound = frame(shots.debugSoundBubble, in: shots)
        #expect(abs(bar.maxX - shots.debugCaptionFrame.maxX) < 0.5, "the strip does not end with the caption")
        #expect(bar.maxX < sound.minX, "the strip runs under the cover")

        // The cover's bottom: the bar's line, less the breath and the rest gap
        // — Shots' 12 pt, another feed's 6 (#1722).
        let barLine = shots.bounds.height - SnapActionColumnLayoutTests.insets.bottom
        let plainSound = frame(plain.debugSoundBubble, in: plain)
        #expect(abs(sound.maxY - (barLine - SnapActionColumn.shotsBottomBreath - SnapActionColumn.inputRestingGap)) < 0.5,
                "Shots' cover is not its breath over the bar")
        #expect(abs(plainSound.maxY - (barLine - SnapActionColumn.bottomBreath - SnapActionColumn.inputRestingGap)) < 0.5,
                "another feed's cover is not its breath over the bar")
        #expect(abs(frame(plain.debugPageBar, in: plain).minY - bar.minY
            - (SnapActionColumn.shotsBottomBreath - SnapActionColumn.bottomBreath)) < 0.5, "the strips are not a breath apart")

        let lone = laidOut(pages: 1, shots: true)
        let loneSound = frame(lone.debugSoundBubble, in: lone)
        #expect(abs(lone.debugCaptionFrame.maxY - loneSound.maxY) < 0.5, "with no strip the caption is not on the cover's line")
    }

    /// Every feed's no-strip caption sits on the cover's line (#1726: the
    /// #1718 trial, made the default).
    @Test func everyFeedsCaptionSitsOnTheCoversLineWithNoStrip() {
        let chrome = SnapActionColumnLayoutTests.chrome()
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
        chrome.setMediaPageCount(1, current: 0)
        chrome.setNeedsLayout()
        chrome.layoutIfNeeded()
        let cover = chrome.debugSoundBubble.convert(chrome.debugSoundBubble.bounds, to: chrome)
        #expect(abs(chrome.debugCaptionFrame.maxY - cover.maxY) < 0.5, "the caption is off the cover's line")
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
        #expect(!capsule.saveButton.isEnabled && !capsule.shareButton.isEnabled)
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
