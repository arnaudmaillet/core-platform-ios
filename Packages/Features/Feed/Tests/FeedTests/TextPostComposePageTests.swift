import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **THE "+" MENU'S TEXT POST IS A TEXT POST'S OWN PAGE, BORN EMPTY — IN A SHEET.**
///
/// The text page's real panel over a DRAFT: nothing fetched, an invitation
/// where the comments would be, writing bars ([Cancel] … [Drafts]) and a footer
/// that offers a sound. The first send publishes the post, and the same panel
/// becomes it — caption row, a composer that comments, the post's own bars.
@MainActor
struct TextPostComposePageTests {
    /// Answers only what it has been told to remember — which is exactly the
    /// just-published post — and counts the reads a draft must never make.
    private final class RememberingFeed: FeedProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var held: [PostID: FeedEntry] = [:]
        private var reads = 0
        var postReads: Int { lock.withLock { reads } }

        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage {
            FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            try lock.withLock {
                reads += 1
                guard let entry = held[id] else { throw FeedError.transport(message: "unknown \(id)") }
                return entry
            }
        }
        nonisolated func peekPost(_ id: PostID) -> FeedEntry? { lock.withLock { held[id] } }
        func remember(_ entry: FeedEntry) async { lock.withLock { held[entry.post.id] = entry } }
    }

    private final class ViewerComments: CommentsProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [PostID: [CommentEntry]] = [:]
        private var loaded: [PostID] = []
        private var addedTo: [PostID] = []
        var loads: [PostID] { lock.withLock { loaded } }
        var added: [PostID] { lock.withLock { addedTo } }
        let viewer = ViewerIdentity(
            name: "Demo Viewer", avatarURL: nil, profileID: ProfileID("prof-me"), handle: "you"
        )

        nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { lock.withLock { pages[postID] } }
        nonisolated func seedTopComments(_ entries: [CommentEntry], for postID: PostID) {
            lock.withLock { pages[postID] = entries }
        }
        nonisolated func cachedViewerIdentity() -> ViewerIdentity? { viewer }
        func viewerIdentity() async -> ViewerIdentity? { viewer }
        func loadComments(for postID: PostID) async throws -> [CommentEntry] {
            lock.withLock {
                loaded.append(postID)
                return pages[postID] ?? []
            }
        }
        func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
            lock.withLock { addedTo.append(postID) }
            return CommentEntry(
                id: "comment-1", authorID: ProfileID("prof-me"), authorName: "Demo Viewer",
                authorHandle: "you", body: body, createdAt: Date()
            )
        }
    }

    private final class RecordingPublisher: TextPostPublishing, @unchecked Sendable {
        struct Call {
            let text: String
            let author: AuthorSummary?
        }
        private let lock = NSLock()
        private var recorded: [Call] = []
        var calls: [Call] { lock.withLock { recorded } }
        /// How long the round trip takes — a post "on its way".
        var delay: Duration = .zero

        func publishTextPost(_ text: String, as author: AuthorSummary?) async throws -> FeedEntry {
            lock.withLock { recorded.append(Call(text: text, author: author)) }
            if delay > .zero { try await Task.sleep(for: delay) }
            let by = author ?? AuthorSummary(id: ProfileID("prof-first"), handle: "first", displayName: "First", avatarURL: nil)
            return FeedEntry(
                post: Post(id: PostID("post-new"), authorID: by.id, caption: text, attachments: [], publishedAt: Date()),
                author: by
            )
        }
    }

    private struct Page {
        let window: UIWindow
        let navigation: UINavigationController
        let composer: TextPostComposerViewController
        let panel: PostDetailViewController
        let posts: RememberingFeed
        let comments: ViewerComments
        let publisher: RecordingPublisher
        let drafts: PostDraftStore
    }

    /// Hosted as the window's root: a unit test's window has no scene to
    /// present a sheet into. The drafts live in a file of the test's own.
    /// `contentSize` is pinned, never inherited: the page's geometry follows
    /// the text size, and a simulator left at an accessibility size would turn
    /// every geometry expectation here red for a reason no test names.
    private func openPage(
        size: CGSize = CGSize(width: 390, height: 844),
        contentSize: UIContentSizeCategory = .large
    ) async throws -> Page {
        let posts = RememberingFeed()
        let comments = ViewerComments()
        let publisher = RecordingPublisher()
        let draftsFile = "post-drafts-test-\(UUID().uuidString)"
        try CodableFileStore<[PostDraft]>(name: draftsFile).clear()
        let drafts = PostDraftStore(name: draftsFile)
        let screen = FeedFeatureBuilder(
            repository: posts,
            commentsProvider: comments,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            postDrafts: drafts
        ).makeTextPostScreen(publisher: publisher)
        let navigation = try #require(screen as? UINavigationController)
        #expect(navigation.modalPresentationStyle == .pageSheet, "a sheet, not a full screen")
        let composer = try #require(navigation.viewControllers.first as? TextPostComposerViewController)

        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.traitOverrides.preferredContentSizeCategory = contentSize
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        let panel = try #require(composer.children.first as? PostDetailViewController)
        try await settle { !Self.all(CommentsEmptyPageCell.self, in: panel.view).isEmpty }
        panel.view.layoutIfNeeded()
        return Page(
            window: window, navigation: navigation, composer: composer, panel: panel,
            posts: posts, comments: comments, publisher: publisher, drafts: drafts
        )
    }

    private func publish(_ page: Page, _ text: String = "Hello from the page") async throws {
        page.panel.debugSend(text)
        try await settle { page.composer.debugIsPublished }
        page.panel.view.layoutIfNeeded()
    }

    private func settle(until condition: () -> Bool) async throws {
        var attempts = 0
        while !condition(), attempts < 300 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    private static func texts(in view: UIView) -> [String] {
        all(UILabel.self, in: view).compactMap(\.text)
    }

    // MARK: - Writing

    @Test func theDraftIsAnEmptyTextPageThatInvitesThePost() async throws {
        let page = try await openPage()

        let empty = try #require(Self.all(CommentsEmptyPageCell.self, in: page.panel.view).first)
        #expect(Self.texts(in: empty).contains("Start your post"))
        #expect(Self.texts(in: empty).contains("Your first message becomes the post."))
        #expect(Self.all(CaptionBubbleCell.self, in: page.panel.view).isEmpty, "nothing is written yet")
        #expect(Self.all(CommentSkeletonRowView.self, in: page.panel.view).isEmpty, "empty because new, not loading")
    }

    /// ⚠️ ON AN IPHONE SE, AT THE SHEET'S MEDIUM HEIGHT, THE STREAM HAS LESS
    /// ROOM THAN THE EMPTY PAGE USED TO INSIST ON (a flat 260pt), and "Start
    /// your post" sat behind the composer. The invitation is centred in what
    /// is visible between the header and the composer instead.
    @Test func theInvitationIsCentredInTheVisibleStreamOfAShortSheet() async throws {
        // A short sheet: 60pt more room than the block — enough to centre in,
        // and well under the 260pt the page used to insist on. Sized from the
        // page's own floor (its chrome plus the block), because a scene-less
        // test window's bars are far taller than a sheet's: a fixed 340pt
        // window left the stream less room than the block.
        let probe = try await openPage(size: CGSize(width: 375, height: 340))
        let floor = try #require(probe.composer.debugRestingFloor)
        let page = try await openPage(size: CGSize(width: 375, height: floor + 60))
        let panel = try #require(page.panel.view)
        let stream = try #require(Self.all(UICollectionView.self, in: panel).first)
        let bar = try #require(Self.all(CommentsInputBar.self, in: panel).first)
        let empty = try #require(Self.all(EmptyStateView.self, in: panel).first)
        let stack = try #require(Self.all(UIStackView.self, in: empty).first)
        #expect(Self.texts(in: stack).contains("Start your post"))

        let block = stack.convert(stack.bounds, to: panel)
        // A row with no room to spare leaves nothing to centre: this test would
        // then be measuring the floor, not the centring, and say so here.
        let row = try #require(Self.all(CommentsEmptyPageCell.self, in: panel).first)
        #expect(row.bounds.height > block.height + Spacing.lg, "room to centre in: row \(row.bounds.height), block \(block.height)")
        let visibleTop = stream.convert(stream.bounds, to: panel).minY + stream.contentInset.top
        let composerTop = bar.convert(bar.bounds, to: panel).minY
        #expect(block.minY >= visibleTop, "the invitation starts below the header: \(block) vs \(visibleTop)")
        #expect(block.maxY <= composerTop, "the invitation clears the composer: \(block) vs \(composerTop)")
        // Centred in the space a reader sees as empty: from the header's foot
        // (the stream starts a breath below it) down to the composer's top.
        let above = block.minY - (visibleTop - SnapCommentsLayout.streamTopBreath)
        let below = composerTop - block.maxY
        #expect(abs(above - below) <= 1, "centred: \(above) above, \(below) below")
    }

    /// The medium height, unless the invitation needs more — and never past
    /// the sheet's largest height.
    @Test func theRestingHeightIsMediumUnlessTheInvitationNeedsMore() {
        typealias Composer = TextPostComposerViewController
        #expect(Composer.restingHeight(medium: 330, maximum: 620, floor: nil) == 330)
        #expect(Composer.restingHeight(medium: 330, maximum: 620, floor: 280) == 330)
        #expect(Composer.restingHeight(medium: 330, maximum: 620, floor: 410) == 410)
        #expect(Composer.restingHeight(medium: 330, maximum: 620, floor: 900) == 620)
    }

    /// Large text on a short sheet: the invitation cannot fit the medium
    /// height, so the sheet rests just tall enough to show it whole.
    ///
    /// Also proves the block is MEASURED at the screen's text size: measured
    /// at the app's instead, both floors would come out the same.
    @Test func theSheetRestsTallerWhenTheInvitationCannotFit() async throws {
        let short = CGSize(width: 375, height: 340)
        let regular = try await openPage(size: short)
        let regularFloor = try #require(regular.composer.debugRestingFloor)
        let large = try await openPage(size: short, contentSize: .accessibilityExtraExtraExtraLarge)
        let largeFloor = try #require(large.composer.debugRestingFloor)

        #expect(largeFloor > regularFloor + 50, "the block grows with the text size: \(regularFloor) → \(largeFloor)")
        #expect(largeFloor > short.height, "more than a short sheet leaves it: \(largeFloor)")
    }

    /// The text size changes while the sheet is open: the least it rests at
    /// follows, without the sheet being reopened.
    @Test func theRestingHeightFollowsALiveTextSizeChange() async throws {
        let page = try await openPage(size: CGSize(width: 375, height: 340))
        let before = try #require(page.composer.debugRestingFloor)

        page.window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        page.window.layoutIfNeeded()
        try await settle { (page.composer.debugRestingFloor ?? 0) > before + 50 }

        let after = try #require(page.composer.debugRestingFloor)
        #expect(after > before + 50, "the floor follows the text size: \(before) → \(after)")
    }

    /// At the height the sheet rests at, the whole invitation clears the
    /// composer — at the largest text size too, where the composer's empty
    /// field is about twice its usual height.
    @Test func atItsRestingFloorTheInvitationClearsTheComposer() async throws {
        let largest = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        let probe = try await openPage(size: CGSize(width: 375, height: 340), contentSize: largest)
        let floor = try #require(probe.composer.debugRestingFloor)

        // The sheet at that floor: a test window has no bottom safe area, so
        // the floor is the whole height.
        let page = try await openPage(size: CGSize(width: 375, height: floor), contentSize: largest)
        let panel = try #require(page.panel.view)
        let stream = try #require(Self.all(UICollectionView.self, in: panel).first)
        let bar = try #require(Self.all(CommentsInputBar.self, in: panel).first)
        let empty = try #require(Self.all(EmptyStateView.self, in: panel).first)
        let stack = try #require(Self.all(UIStackView.self, in: empty).first)

        let block = stack.convert(stack.bounds, to: panel)
        let visibleTop = stream.convert(stream.bounds, to: panel).minY + stream.contentInset.top
        let composerTop = bar.convert(bar.bounds, to: panel).minY
        #expect(block.minY >= visibleTop - 0.5, "below the header: \(block) vs \(visibleTop)")
        #expect(block.maxY <= composerTop + 0.5, "clear of a \(bar.bounds.height)pt composer: \(block) vs \(composerTop)")
    }

    @Test func theDraftNeverFetches() async throws {
        let page = try await openPage()
        try await Task.sleep(for: .milliseconds(100))

        #expect(page.posts.postReads == 0)
        #expect(page.comments.loads.isEmpty)
    }

    /// [Cancel] … [Drafts] — and neither the author nor the balance, which
    /// belong to a post that exists.
    @Test func theWritingBarsAreCancelAndDrafts() async throws {
        let page = try await openPage()

        let leading = page.composer.navigationItem.leftBarButtonItems ?? []
        let trailing = page.composer.navigationItem.rightBarButtonItems ?? []
        #expect(leading.map(\.title) == ["Cancel"])
        #expect(trailing.map(\.title) == ["Drafts"])
        #expect(!(leading + trailing).contains { $0.customView is SnapAuthorIdentityView })
        #expect(!(leading + trailing).contains { $0.customView is WalletBadgeButton })
    }

    @Test func theFooterLeadsWithASoundToAdd() async throws {
        let page = try await openPage()

        let leading = try #require(page.composer.toolbarItems?.first?.customView)
        #expect(leading.accessibilityLabel == "Add a sound and a cover")
    }

    /// While the keyboard is up it covers the footer, so the sound pill rides in
    /// the top bar inboard of Drafts — and goes home with the keyboard.
    @Test func theSoundPillFollowsTheKeyboard() async throws {
        let page = try await openPage()
        let label = "Add a sound and a cover"
        func onTop() -> Bool {
            (page.composer.navigationItem.rightBarButtonItems ?? []).contains { $0.customView?.accessibilityLabel == label }
        }
        func inFooter() -> Bool {
            (page.composer.toolbarItems ?? []).contains { $0.customView?.accessibilityLabel == label }
        }
        #expect(!onTop() && inFooter())

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        try await settle { onTop() }
        #expect(onTop() && !inFooter())
        #expect(page.composer.navigationItem.rightBarButtonItems?.first?.title == "Drafts", "Drafts keeps the edge")

        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await settle { inFooter() }
        #expect(!onTop() && inFooter())
    }

    /// The boost's slot asks who will see the post; the star waits for a post.
    @Test func theComposerOffersVisibilityInsteadOfBoost() async throws {
        let page = try await openPage()

        let bar = try #require(Self.all(CommentsInputBar.self, in: page.panel.view).first)
        let buttons = Self.all(UIButton.self, in: bar)
        #expect(buttons.contains { $0.accessibilityLabel == "Post visibility" && !$0.isHidden })
        #expect(buttons.contains { $0.accessibilityLabel == "Boost post" && $0.isHidden })
        #expect(Self.texts(in: bar).contains("Post as Demo Viewer"))
    }

    // MARK: - Publishing

    @Test func theFirstSendPublishesOnceAsTheComposersFace() async throws {
        let page = try await openPage()

        try await publish(page, "  Hello from the page  ")

        #expect(page.publisher.calls.map(\.text) == ["Hello from the page"])
        #expect(page.publisher.calls.first?.author?.id == ProfileID("prof-me"))
    }

    /// The SAME panel becomes the post, and the bars become the post's.
    @Test func publishingTurnsThePageIntoThePost() async throws {
        let page = try await openPage()

        try await publish(page)
        try await settle { !Self.all(CaptionBubbleCell.self, in: page.panel.view).isEmpty }

        #expect(page.composer.children.first === page.panel, "never rebuilt, never re-parented")
        let caption = try #require(Self.all(CaptionBubbleCell.self, in: page.panel.view).first)
        #expect(Self.texts(in: caption).contains("Hello from the page"))
        let empty = try #require(Self.all(CommentsEmptyPageCell.self, in: page.panel.view).first)
        #expect(Self.texts(in: empty).contains(SnapCommentEmptyStateView.promptText))

        let leading = page.composer.navigationItem.leftBarButtonItems ?? []
        #expect(leading.first?.customView?.accessibilityLabel == "Close")
        #expect(!leading.contains { $0.customView is SnapCommentSortButton }, "no sort for a thread of none")
        #expect((page.composer.navigationItem.rightBarButtonItems ?? []).contains { $0.customView is SnapAuthorIdentityView })
        #expect(page.composer.toolbarItems?.first?.customView is SnapMediaAttributionView)
        let bar = try #require(Self.all(CommentsInputBar.self, in: page.panel.view).first)
        #expect(Self.all(UIButton.self, in: bar).contains { $0.accessibilityLabel == "Boost post" && !$0.isHidden })
    }

    @Test func commentsAfterPublishTargetTheNewPost() async throws {
        let page = try await openPage()
        try await publish(page)
        try await Task.sleep(for: .milliseconds(50))

        page.panel.debugSend("First comment")
        try await settle { !page.comments.added.isEmpty }

        #expect(page.comments.added == [PostID("post-new")])
    }

    // MARK: - Leaving and drafts

    @Test func cancellingWrittenTextOffersToSaveIt() async throws {
        let page = try await openPage()
        page.panel.composerText = "Half a thought"

        page.composer.navigationItem.leftBarButtonItems?.first?.primaryAction?.performWithSender(nil, target: nil)
        try await settle { page.navigation.presentedViewController != nil }

        let sheet = try #require(page.navigation.presentedViewController as? UIAlertController)
        #expect(sheet.actions.map(\.title) == ["Save Draft", "Delete Draft", "Keep Editing"])
    }

    @Test func cancellingAnEmptyPageAsksNothing() async throws {
        let page = try await openPage()

        page.composer.navigationItem.leftBarButtonItems?.first?.primaryAction?.performWithSender(nil, target: nil)
        try await Task.sleep(for: .milliseconds(50))

        #expect(page.navigation.presentedViewController == nil)
    }

    /// Writing makes a swipe ask first; an empty page may be swiped away.
    @Test func unsavedWritingGuardsTheSwipe() async throws {
        let page = try await openPage()
        #expect(page.navigation.isModalInPresentation == false)

        page.panel.composerText = "Half a thought"
        #expect(page.navigation.isModalInPresentation)

        page.panel.composerText = ""
        #expect(page.navigation.isModalInPresentation == false)
    }

    @Test func savingADraftKeepsItForLater() async throws {
        let page = try await openPage()
        page.panel.composerText = "For later"

        page.composer.saveDraftAndClose()

        #expect(page.drafts.drafts.map(\.text) == ["For later"])
    }

    /// A draft opens in the composer, and publishing it removes it from the list.
    @Test func aPublishedDraftLeavesTheList() async throws {
        let page = try await openPage()
        let draft = try #require(page.drafts.save("From a draft"))

        page.composer.open(draft)
        #expect(page.panel.composerText == "From a draft")
        #expect(page.navigation.isModalInPresentation == false, "unchanged from its saved draft")

        try await publish(page, "From a draft")

        #expect(page.drafts.drafts.isEmpty)
    }

    /// Tapping the draft that is already open keeps the edits on screen — its
    /// row was read before they were made.
    @Test func reopeningTheOpenDraftKeepsTheEdits() async throws {
        let page = try await openPage()
        let draft = try #require(page.drafts.save("Hello"))
        page.composer.open(draft)
        page.panel.composerText = "Hello world"

        page.composer.open(draft)

        #expect(page.panel.composerText == "Hello world")
    }

    /// Deleting the open draft from the list turns its text back into writing
    /// nothing else keeps — so a swipe asks again.
    @Test func deletingTheOpenDraftGuardsTheSwipeAgain() async throws {
        let page = try await openPage()
        let draft = try #require(page.drafts.save("Kept only here"))
        page.composer.open(draft)
        #expect(page.navigation.isModalInPresentation == false)

        page.drafts.delete(draft.id)

        #expect(page.navigation.isModalInPresentation)
    }

    /// A post on its way holds the sheet, and no other draft can be opened
    /// into it: it still belongs to the draft it came from.
    @Test func aPostOnItsWayHoldsTheSheet() async throws {
        let page = try await openPage()
        page.publisher.delay = .milliseconds(400)
        let other = try #require(page.drafts.save("Another draft"))

        page.panel.debugSend("On its way")
        try await settle { page.panel.isPublishing }
        #expect(page.navigation.isModalInPresentation, "the sheet holds while the post is on its way")
        page.composer.open(other)
        #expect(page.panel.composerText.isEmpty, "no draft opens into a post on its way")

        try await settle { page.composer.debugIsPublished }
        try await settle { !page.panel.isPublishing }
        #expect(page.navigation.isModalInPresentation == false)
        #expect(page.drafts.drafts.map(\.text) == ["Another draft"], "the other draft is untouched")
    }
}
