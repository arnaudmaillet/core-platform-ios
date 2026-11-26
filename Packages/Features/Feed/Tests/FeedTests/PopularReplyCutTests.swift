import CoreModels
import MediaCore
import MediaCoreFixtures
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

private final class NoPostFeed: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}

private func comment(_ index: Int) -> CommentEntry {
    CommentEntry(
        id: "c\(index)", authorID: ProfileID("other"), authorName: "Ava Moreau", authorHandle: "ava",
        body: index % 3 == 0 ? "Comment \(index), long enough to take a second line in the row at this width"
            : "Comment \(index)",
        createdAt: Date(timeIntervalSinceNow: -Double(index) * 60)
    )
}

/// `count` top-level comments, one page for both tabs; what the viewer sends
/// comes back as theirs, under the parent it names.
private actor RankedComments: CommentsProviding {
    let all: [CommentEntry]

    init(count: Int) { all = (0..<count).map(comment) }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { all }
    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        CommentPage(entries: all, nextPageToken: nil)
    }
    func loadCommentsPage(
        for postID: PostID, after pageToken: String?, order: CommentSortOrder
    ) async throws -> CommentPage {
        CommentPage(entries: all, nextPageToken: nil)
    }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        CommentEntry(
            id: commentID, authorID: ProfileID("me"), authorName: "Me", authorHandle: "me",
            body: body, createdAt: Date(), parentID: parentID
        )
    }
}

/// **A SENT REPLY KEEPS POPULAR'S CUT (#2572, decision A).** Popular is cut to
/// the whole threads that fit its room (#2298). The viewer's own reply never
/// changes which threads it shows: the thread replied to stays, its reply
/// under it, and so does every thread shown before. The stream grows past
/// its room and scrolls instead, as it does for a thread the reader opens.
/// The viewer's own top-level comment keeps leading Popular and is cut as
/// before (#2007).
@MainActor
@Suite(.serialized)
struct PopularReplyCutTests {
    private static let looks = 3_000
    private static let size = CGSize(width: 402, height: 874)
    /// A reply far taller than whatever room a cut leaves under its last
    /// thread: that room is shorter than one more thread.
    private static let longReply = Array(
        repeating: "A reply that goes on about the light over the harbour at dawn.", count: 10
    ).joined(separator: " ")

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<Self.looks where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A text page in a vertical feed: the room's rules on.
    private func page() -> (PostDetailViewController, UIWindow) {
        let controller = Self.controller()
        // ⚠️ NOT THE SYSTEM KEYBOARD (#2392): the reply focuses the field.
        controller.setComposerTracksKeyboard(false)
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        window.rootViewController = controller
        window.isHidden = false
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        controller.setEngagedPageSwipeHandler({ _, _, _ in }, pagesBack: { false })
        controller.seedCaption("A text post", timestamp: "2h", authorName: "Ava Moreau")
        return (controller, window)
    }

    /// A media post's comments sheet, at its resting height.
    private func sheet() -> (PostDetailViewController, UIWindow) {
        let detail = Self.controller()
        detail.setComposerTracksKeyboard(false)
        detail.seedCaption("A post", timestamp: "2h", authorName: "Ava Moreau")
        SnapCommentsSheetViewController.prepare(detail, commentCount: 40)
        let content = SnapCommentsSheetViewController(panel: detail, walletBadge: nil, onWalletTap: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.size.width, height: 520))
        window.rootViewController = content
        window.isHidden = false
        content.composerBottomInset = 34
        content.loadViewIfNeeded()
        content.view.layoutIfNeeded()
        content.applyPanelInsets()
        return (detail, window)
    }

    private static func controller() -> PostDetailViewController {
        PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: PostID("p"), repository: NoPostFeed(), commentsProvider: RankedComments(count: 40)
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
    }

    /// Cut, laid out, "See all" last.
    private func settleCut(_ stream: CommentStream) async -> Bool {
        await settle {
            stream.collectionView.layoutIfNeeded()
            return stream.commentsLoaded && stream.collectionView.contentSize.height > 0
                && stream.debugItems.last == .seeAll
        }
    }

    /// The threads Popular shows, by their top-level comment.
    private static func threads(_ stream: CommentStream) -> [String] {
        stream.debugItems.compactMap { item in
            guard case .comment(let id) = item, id.hasPrefix("c"), Int(id.dropFirst()) != nil else { return nil }
            return id
        }
    }

    /// The viewer's comments Popular shows: neither the caption nor one of the page's.
    private static func sent(_ stream: CommentStream) -> [String] {
        stream.debugItems.compactMap { item in
            guard case .comment(let id) = item, !threads(stream).contains(id) else { return nil }
            return id
        }
    }

    private static func rowsHeight(_ stream: CommentStream, _ controller: PostDetailViewController) -> CGFloat {
        stream.collectionView.layoutIfNeeded()
        return stream.collectionView.contentSize.height - controller.streamSectionVerticalInsets
    }

    /// Sends `text` as the composer does: a reply to `parentID`'s thread,
    /// armed from its row, or a top-level comment.
    private func send(_ text: String, replyingTo parentID: String?, in controller: PostDetailViewController) {
        if let parentID, let index = Int(parentID.dropFirst()) {
            controller.composeBar.debugTextView.raisesNoKeyboard()
            controller.enterReplyState(for: CommentDisplayModel(entry: comment(index)))
        }
        controller.composeBar.onSend?(text)
    }

    /// A reply that the cut would no longer have room for, sent to `which`
    /// thread: the last one shown, or the first (a neighbour above the last).
    private func replyKeepsTheCut(
        _ controller: PostDetailViewController, toLast: Bool
    ) async throws {
        let stream = controller.popular
        #expect(await settleCut(stream))
        let before = Self.threads(stream)
        #expect(!before.isEmpty && before.count < 40, "\(before.count) threads")
        let parent = try #require(toLast ? before.last : before.first)

        send(Self.longReply, replyingTo: parent, in: controller)
        #expect(await settle { Self.sent(stream).count == 1 })

        #expect(Self.threads(stream) == before, "a sent reply changed the threads Popular shows")
        let reply = try #require(Self.sent(stream).first)
        let items = stream.debugItems
        let parentIndex = try #require(items.firstIndex(of: .comment(parent)))
        #expect(items[parentIndex + 1] == .comment(reply), "the reply is not under its thread")
        #expect(items.last == .seeAll)
        // The scenario itself: the threads at rest, the reply in, are taller
        // than the room — so a cut decided again would have dropped one.
        #expect(await settle { Self.rowsHeight(stream, controller) > stream.debugCutRoom + 1 },
                "\(Self.rowsHeight(stream, controller)) of rows in a room of \(stream.debugCutRoom)")
        #expect(!stream.streamFitsItsRoom, "the stream past its room scrolls")
    }

    /// ⚠️ ON THE TEXT PAGE: the last thread replied to stays, its reply under
    /// it, and so does every thread before it; a reply to the first thread
    /// takes none of its neighbours away either.
    @Test(arguments: [true, false])
    func aSentReplyKeepsEveryThreadOnThePage(toLast: Bool) async throws {
        let (controller, window) = page()
        defer {
            controller.composeBar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        try await replyKeepsTheCut(controller, toLast: toLast)
    }

    /// ⚠️ IN THE COMMENTS SHEET, at its resting height: the same.
    @Test(arguments: [true, false])
    func aSentReplyKeepsEveryThreadInTheSheet(toLast: Bool) async throws {
        let (controller, window) = sheet()
        defer {
            controller.composeBar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        try await replyKeepsTheCut(controller, toLast: toLast)
    }

    /// The viewer's own top-level comment is as before (#2007): it leads
    /// Popular, and Popular is still cut to its room — a thread may go past
    /// "See all" for it.
    @Test func anOwnTopLevelCommentLeadsAndIsCutAsBefore() async throws {
        let (controller, window) = page()
        defer { window.isHidden = true }
        let stream = controller.popular
        #expect(await settleCut(stream))
        let before = Self.threads(stream)

        send(Self.longReply, replyingTo: nil, in: controller)
        #expect(await settle { Self.sent(stream).count == 1 })

        let own = try #require(Self.sent(stream).first)
        let items = stream.debugItems
        #expect(Array(items.prefix(2)) == [.caption, .comment(own)], "the viewer's comment leads Popular")
        let after = Self.threads(stream)
        #expect(after.count < before.count, "the long comment took no thread's place")
        #expect(Array(before.prefix(after.count)) == after)
        #expect(items.last == .seeAll)
        #expect(await settle { Self.rowsHeight(stream, controller) <= stream.debugCutRoom + 1 },
                "\(Self.rowsHeight(stream, controller)) of rows in a room of \(stream.debugCutRoom)")
    }
}
