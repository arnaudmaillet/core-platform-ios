import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A text post's comments with the unified thread's chrome ON
/// (`-unified-thread`): threads grouped under a pinned day pill in Recent
/// order, one section in Trending, and the long press owned by the stream.
///
/// The flag-OFF shape is `PostDetailStreamShapeTests`; together they pin both
/// sides of the one parameter.
@MainActor
struct UnifiedThreadChromeTests {
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

    private final class Prefetched: CommentsProviding, @unchecked Sendable {
        let entries: [CommentEntry]
        init(_ entries: [CommentEntry]) { self.entries = entries }
        nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { entries }
        func loadComments(for postID: PostID) async throws -> [CommentEntry] { entries }
        func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
            throw CommentsError.transport(message: "not used")
        }
    }

    private static func entry(_ id: String, ageInDays: Double, parent: String? = nil) -> CommentEntry {
        CommentEntry(
            id: id, authorID: ProfileID("prof-1"), authorName: "Ava Moreau", authorHandle: "ava",
            body: "Comment \(id)", createdAt: Date().addingTimeInterval(-ageInDays * 86_400), parentID: parent
        )
    }

    /// Newest first, the way Recent reads: today, the day before, three back.
    private static let spreadAcrossDays = [
        entry("c1", ageInDays: 0), entry("c2", ageInDays: 1.2), entry("c3", ageInDays: 3),
    ]

    private func makeStream(
        _ entries: [CommentEntry]
    ) async throws -> (PostDetailViewController, UICollectionView, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: PostID("p"), repository: NoPostFeed(), commentsProvider: Prefetched(entries)
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .commentsOnly,
            threadChrome: true
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.seedCaption("A text post", timestamp: "2h", authorName: "Ava Moreau")
        let stream = try #require(Self.firstView(UICollectionView.self, in: controller.view))
        try await settle { stream.numberOfSections > 1 }
        stream.layoutIfNeeded()
        return (controller, stream, window)
    }

    private func settle(until condition: () -> Bool) async throws {
        var attempts = 0
        while !condition(), attempts < 500 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    @Test func recentGroupsTheThreadsUnderOnePillPerDay() async throws {
        let (_, stream, _) = try await makeStream(Self.spreadAcrossDays)
        #expect(stream.numberOfSections == 4, "the caption, then one section per day")
        #expect(stream.numberOfItems(inSection: 0) == 1, "the caption stands alone, without a pill")
        #expect((1...3).map { stream.numberOfItems(inSection: $0) } == [1, 1, 1])
        let pill = stream.supplementaryView(
            forElementKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: 1)
        )
        #expect(pill is DayPillHeaderView)
    }

    @Test func aReplyStaysUnderTheDayItsThreadBegan() async throws {
        let entries = [
            Self.entry("c1", ageInDays: 0),
            Self.entry("c2", ageInDays: 1.2),
            // Written today, answering yesterday's thread.
            Self.entry("r1", ageInDays: 0, parent: "c2"),
        ]
        let (_, stream, _) = try await makeStream(entries)
        #expect(stream.numberOfSections == 3)
        #expect(stream.numberOfItems(inSection: 2) == 2, "yesterday's thread keeps its reply")
    }

    @Test func trendingHasNoChronologyToPin() async throws {
        let (controller, stream, _) = try await makeStream(Self.spreadAcrossDays)
        controller.setCommentSortOrder(.trending)
        try await settle { stream.numberOfSections == 1 }
        #expect(stream.numberOfSections == 1)
        controller.setCommentSortOrder(.recent)
        try await settle { stream.numberOfSections == 4 }
        #expect(stream.numberOfSections == 4)
    }

    @Test func theStreamOwnsTheLongPressAndRowsCarryNone() async throws {
        let (_, stream, _) = try await makeStream(Self.spreadAcrossDays)
        let cell = try #require(stream.cellForItem(at: IndexPath(item: 0, section: 1)) as? ThreadRowCell)
        #expect(!cell.row.interactions.contains { $0 is UIContextMenuInteraction })
        #expect(stream.interactions.filter { $0 is UIContextMenuInteraction }.count == 1)
    }

    /// The lift plate is what the platter takes, and its bounds are the shape.
    @Test func theLiftIsTheRowsPlate() async throws {
        let (_, stream, _) = try await makeStream(Self.spreadAcrossDays)
        let cell = try #require(stream.cellForItem(at: IndexPath(item: 0, section: 1)) as? ThreadRowCell)
        let preview = cell.liftPreview()
        let path = try #require(preview.parameters.visiblePath)
        #expect(path.bounds == preview.view.bounds)
        #expect(preview.view !== cell.row, "the plate, with its margin, not the bare row")
    }
}
