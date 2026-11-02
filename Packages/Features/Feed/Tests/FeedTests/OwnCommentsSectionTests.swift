import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **The viewer's own comments (#921, #2007).** They lead the ranked order —
/// right under the caption, in their own chronology; the rank orders everyone
/// else's — and Popular's stream with it. Recent is a conversation: there the
/// viewer's threads stand in the chronology, the newest at its end. A comment
/// the viewer sends lands where they can see it: the list goes to its slot
/// first, then the comment arrives there.
@MainActor
struct OwnCommentsSectionTests {
    private static let me = ProfileID("me")

    private static func entry(
        _ id: String, by author: ProfileID = ProfileID("other"), parent: String? = nil, minutesAgo: Double = 0
    ) -> CommentEntry {
        CommentEntry(
            id: id, authorID: author, authorName: author == me ? "Me" : "Ava Moreau",
            authorHandle: author == me ? "me" : "ava", body: "Comment \(id)",
            createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60), parentID: parent
        )
    }

    /// Newest first, the repository's chronology: two of the viewer's threads
    /// among others, one with a reply, and a reply of the viewer's in
    /// someone else's thread.
    private static let mixed: [CommentEntry] = [
        entry("a", minutesAgo: 1),
        entry("m1", by: me, minutesAgo: 2),
        entry("b", minutesAgo: 3),
        entry("b-r1", parent: "b", minutesAgo: 2.5),
        entry("b-r2", by: me, parent: "b", minutesAgo: 2.4),
        entry("m2", by: me, minutesAgo: 4),
        entry("m2-r1", parent: "m2", minutesAgo: 3.5),
        entry("c", minutesAgo: 5),
    ]

    // MARK: - The view model

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

    /// Comments as "me": the viewer's face is known on frame one.
    private final class MyComments: CommentsProviding, @unchecked Sendable {
        let entries: [CommentEntry]
        init(_ entries: [CommentEntry]) { self.entries = entries }
        nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { entries }
        nonisolated func cachedViewerIdentity() -> ViewerIdentity? {
            ViewerIdentity(name: "Me", avatarURL: nil, profileID: ProfileID("me"))
        }
        func viewerIdentity() async -> ViewerIdentity? { cachedViewerIdentity() }
        func loadComments(for postID: PostID) async throws -> [CommentEntry] { entries }
        func addComment(
            _ body: String, to postID: PostID, parentID: String?, commentID: String
        ) async throws -> CommentEntry {
            CommentEntry(
                id: commentID, authorID: ProfileID("me"), authorName: "Me", authorHandle: "me",
                body: body, createdAt: Date(), parentID: parentID
            )
        }
    }

    /// A look budget, not a deadline: every wait here is positive and stops
    /// as soon as its condition holds, so the budget only matters on a starved
    /// runner, where each look stretches (#980). It answers, so a timeout
    /// fails at the wait rather than at a stale list read after it.
    private static let looks = 6_000

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<Self.looks where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The models carry who started each thread; Recent keeps the viewer's
    /// in its chronology (#2007), and a comment the viewer sends is its newest
    /// — the end of the conversation.
    @Test func recentKeepsTheViewersThreadsInItsChronology() async {
        let viewModel = PostDetailViewModel(
            postID: PostID("p"), repository: NoPostFeed(), commentsProvider: MyComments(Self.mixed)
        )
        var latest: [CommentDisplayModel] = []
        viewModel.onCommentsChange = { if case .loaded(let models) = $0 { latest = models } }
        viewModel.viewDidLoad()
        #expect(await settle { !latest.isEmpty })
        #expect(latest.map(\.id) == Self.mixed.map(\.id), "Recent moved the viewer's threads")
        #expect(latest.filter(\.isOwnThread).map(\.id) == ["m1", "m2"], "only threads the viewer started")

        viewModel.submitComment("Mine, newest")
        #expect(await settle { latest.count == Self.mixed.count + 1 })
        // Newest first in the view model: the conversation's last message.
        #expect(latest.first?.body == "Mine, newest")
        #expect(latest.first?.isOwnThread == true)
        #expect(latest.dropFirst().map(\.id) == Self.mixed.map(\.id))
    }

    // MARK: - The stream

    private func makeStream(
        _ entries: [CommentEntry], groupsByDay: Bool = false
    ) async throws -> (PostDetailViewController, PostDetailViewModel, UICollectionView, UIWindow) {
        let viewModel = PostDetailViewModel(
            postID: PostID("p"), repository: NoPostFeed(), commentsProvider: MyComments(entries)
        )
        let controller = PostDetailViewController(
            viewModel: viewModel,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            threadChrome: true,
            groupsByDay: groupsByDay
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.seedCaption("A text post", timestamp: "2h", authorName: "Ava Moreau")
        // The tab on screen: Popular for a long thread, Recent for a short one.
        for _ in 0..<Self.looks
        where controller.stream.collectionView.visibleCells.compactMap(PostDetailViewController.commentRow(in:)).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let stream = controller.stream.collectionView
        stream.layoutIfNeeded()
        return (controller, viewModel, stream, window)
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    private static func rowBodies(in stream: UICollectionView, section: Int) -> [String] {
        (0..<stream.numberOfItems(inSection: section)).compactMap { item in
            stream.cellForItem(at: IndexPath(item: item, section: section))
                .flatMap(PostDetailViewController.commentRow(in:))?.bodyTextLabel.text
        }
    }

    /// Grouped by day, Recent's conversation keeps the viewer's threads under
    /// the day they began, like everyone's (#2007): oldest day first.
    @Test func groupedByDayTheViewersThreadsStayInTheirDay() async throws {
        let calendar = Calendar.current
        let noonYesterday = calendar.date(byAdding: .hour, value: -12, to: calendar.startOfDay(for: Date()))!
        func at(_ hoursBefore: Double) -> Double { Date().timeIntervalSince(noonYesterday) / 60 + hoursBefore * 60 }
        let entries = [
            Self.entry("a", minutesAgo: at(0)),
            Self.entry("m", by: Self.me, minutesAgo: at(0.5)),
            Self.entry("b", minutesAgo: at(30)),
        ]
        let (_, _, stream, window) = try await makeStream(entries, groupsByDay: true)
        defer { window.isHidden = true }
        #expect(stream.numberOfSections == 3, "the caption, then one section per day: \(stream.numberOfSections)")
        #expect(Self.rowBodies(in: stream, section: 1) == ["Comment b"])
        #expect(Self.rowBodies(in: stream, section: 2) == ["Comment m", "Comment a"], "the viewer's thread left its day")
    }

    /// Sent from deep in the list, a comment does not land off screen: the
    /// list first goes to its slot — under the caption, on the Popular tab a
    /// long thread opens on — and only then is the comment inserted, on
    /// screen, with its arrival.
    @Test func aCommentSentFromDeepInTheListScrollsToItsSlotThenArrives() async throws {
        let others = (0..<30).map { Self.entry("o\($0)", minutesAgo: Double($0 + 1)) }
        let (controller, viewModel, stream, window) = try await makeStream(others)
        defer { window.isHidden = true }
        let bottom = stream.contentSize.height - stream.bounds.height + stream.adjustedContentInset.bottom
        stream.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        stream.layoutIfNeeded()
        #expect(stream.contentOffset.y > 200, "the stream is not long enough to scroll")

        viewModel.submitComment("Sent from the bottom")
        #expect(await settle { controller.debugLandingEvents.contains { $0.hasPrefix("arrive:") } })
        let events = controller.debugLandingEvents.map { $0.split(separator: ":").first.map(String.init) ?? $0 }
        #expect(events == ["scroll", "insert", "arrive"], "\(controller.debugLandingEvents)")

        let landed = try #require(stream.visibleCells.first {
            PostDetailViewController.commentRow(in: $0)?.bodyTextLabel.text == "Sent from the bottom"
        }, "the comment is not on screen where it landed")
        let frame = landed.convert(landed.bounds, to: stream)
        let visible = stream.bounds.inset(by: stream.adjustedContentInset)
        #expect(visible.intersects(frame), "landed at \(frame), visible \(visible)")
    }

    /// A slot already on screen: no scroll, the comment arrives in place.
    @Test func aCommentWhoseSlotIsOnScreenArrivesWithoutAScroll() async throws {
        let others = (0..<3).map { Self.entry("o\($0)", minutesAgo: Double($0 + 1)) }
        let (controller, viewModel, _, window) = try await makeStream(others)
        defer { window.isHidden = true }
        viewModel.submitComment("Sent from the top")
        #expect(await settle { controller.debugLandingEvents.contains { $0.hasPrefix("arrive:") } })
        let events = controller.debugLandingEvents.map { $0.split(separator: ":").first.map(String.init) ?? $0 }
        #expect(events == ["insert", "arrive"], "\(controller.debugLandingEvents)")
    }
}
