import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **The viewer's own comments lead the stream (#921).** Right under the
/// caption, the threads the viewer started stand in their own section, in
/// their own chronology, whatever the sort; the sort orders everyone else's.
/// And a comment the viewer sends lands where they can see it: the list goes
/// to its slot first, then the comment arrives there.
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

    private static func order(_ sort: CommentSortOrder, liked: Set<String> = [], pageStarts: Set<String> = [],
                              viewer: ProfileID? = me, _ entries: [CommentEntry] = mixed) -> [String] {
        PostDetailViewModel.sortedForDisplay(
            entries, order: sort, liked: liked, pageStarts: pageStarts, viewer: viewer
        ).map(\.id)
    }

    // MARK: - The order

    /// Under each sort the viewer's threads come first, in their own
    /// chronology, replies with them; the viewer's reply in someone else's
    /// thread stays in that thread.
    @Test func theViewersThreadsLeadUnderEverySort() {
        #expect(Self.order(.recent) == ["m1", "m2", "m2-r1", "a", "b", "b-r1", "b-r2", "c"])
        // Trending ranks the others (b has two replies, c is liked once).
        #expect(Self.order(.trending, liked: ["c"]) == ["m1", "m2", "m2-r1", "b", "b-r1", "b-r2", "c", "a"])
        // A like on the viewer's own thread does not move it among the others.
        #expect(Self.order(.trending, liked: ["m2", "m2-r1"]).prefix(3) == ["m1", "m2", "m2-r1"])
    }

    /// Changing the sort reorders only the others: the viewer's section is
    /// the same rows in the same order.
    @Test func changingTheSortReordersOnlyTheOthers() {
        let recent = Self.order(.recent)
        let trending = Self.order(.trending, liked: ["c"])
        #expect(Array(recent.prefix(3)) == Array(trending.prefix(3)))
        #expect(Set(recent.dropFirst(3)) == Set(trending.dropFirst(3)))
        #expect(Array(recent.dropFirst(3)) != Array(trending.dropFirst(3)), "the others did not reorder")
    }

    /// No viewer known: the stream is exactly what it was.
    @Test func withNoViewerTheStreamIsUnchanged() {
        #expect(Self.order(.recent, viewer: nil) == Self.mixed.map(\.id))
        #expect(Self.order(.trending, viewer: nil) == PostDetailViewModel.sortedForDisplay(
            Self.mixed, order: .trending, liked: []
        ).map(\.id))
    }

    /// A page that began with one of the viewer's threads still begins a page
    /// at the next thread: Trending never lifts a later page's thread above
    /// rows already on screen.
    @Test func aPageThatStartedWithTheViewersThreadStillStartsAPage() {
        let entries = [
            Self.entry("a"),
            Self.entry("m", by: Self.me),
            Self.entry("b"),
            Self.entry("b-r", parent: "b"),
        ]
        // "m" opened the second page: "b" (one reply) must not outrank "a".
        #expect(Self.order(.trending, pageStarts: ["m"], entries) == ["m", "a", "b", "b-r"])
        #expect(Self.order(.trending, entries) == ["m", "b", "b-r", "a"])
    }

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

    /// The models carry who started each thread, and a comment the viewer
    /// sends joins their section at its head — under any sort.
    @Test func aSentCommentHeadsTheViewersSection() async {
        let viewModel = PostDetailViewModel(
            postID: PostID("p"), repository: NoPostFeed(), commentsProvider: MyComments(Self.mixed)
        )
        var latest: [CommentDisplayModel] = []
        viewModel.onCommentsChange = { if case .loaded(let models) = $0 { latest = models } }
        viewModel.viewDidLoad()
        #expect(await settle { !latest.isEmpty })
        #expect(latest.prefix(3).map(\.id) == ["m1", "m2", "m2-r1"])
        #expect(latest.filter(\.isOwnThread).map(\.id) == ["m1", "m2"], "only threads the viewer started")

        viewModel.setCommentSort(.trending)
        viewModel.submitComment("Mine, newest")
        #expect(await settle { latest.count == Self.mixed.count + 1 })
        #expect(latest.first?.body == "Mine, newest")
        #expect(latest.first?.isOwnThread == true)
        #expect(latest.prefix(4).dropFirst().map(\.id) == ["m1", "m2", "m2-r1"])
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
        let stream = try #require(Self.firstView(UICollectionView.self, in: controller.view))
        for _ in 0..<Self.looks where stream.visibleCells.compactMap(PostDetailViewController.commentRow(in:)).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
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

    /// Grouped by day, the viewer's threads stay in the caption's section,
    /// above every day's pill — a day does not gather the others up under
    /// them.
    @Test func groupedByDayTheViewersThreadsRideWithTheCaption() async throws {
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
        #expect(stream.numberOfSections >= 3, "caption + own, then one section per day: \(stream.numberOfSections)")
        #expect(Self.rowBodies(in: stream, section: 0) == ["Comment m"], "the viewer's thread left the caption's section")
        #expect(Self.rowBodies(in: stream, section: 1) == ["Comment a"])
    }

    /// Sent from deep in the list, a comment does not land off screen: the
    /// list first goes to its slot under the caption, and only then is the
    /// comment inserted — on screen — with its arrival.
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
