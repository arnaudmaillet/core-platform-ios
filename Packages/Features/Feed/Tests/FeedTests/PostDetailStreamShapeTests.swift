import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE COMMENT STREAM'S SHAPE, AS IT SHIPS — pinned before the unified-thread
/// work (`-unified-thread`) adds day sections and a lifted menu behind a
/// parameter that defaults to off.
///
/// Only a handful of tests built this controller before, and none of them
/// looked at its sections, its rows' menus or its engaged footer, so a change
/// that leaked past the default would have passed the whole suite. These are
/// the facts the flag-off path must keep: one section whatever the comments'
/// days, a menu carried by each ROW and none by the stream, and the footer
/// capping the view with the stream inset under it.
@MainActor
struct PostDetailStreamShapeTests {
    /// The post never arrives: these tests are about the stream, which the
    /// seeded caption leads without it.
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

    private static func entry(_ id: String, ageInDays: Double) -> CommentEntry {
        CommentEntry(
            id: id, authorID: ProfileID("prof-1"), authorName: "Ava Moreau", authorHandle: "ava",
            body: "Comment \(id)", createdAt: Date().addingTimeInterval(-ageInDays * 86_400)
        )
    }

    /// Comments from today, the day before and three days back: exactly the
    /// spread the flag-on stream splits into three day sections.
    private static let spreadAcrossDays = [
        entry("c1", ageInDays: 0), entry("c2", ageInDays: 1.2), entry("c3", ageInDays: 3),
    ]

    /// The resting text page's construction, in a window so rows realize.
    private func makeStream(
        _ entries: [CommentEntry]
    ) async throws -> (PostDetailViewController, UICollectionView, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: PostID("p"),
                repository: NoPostFeed(),
                commentsProvider: Prefetched(entries)
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .commentsOnly
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.seedCaption("A text post", timestamp: "2h", authorName: "Ava Moreau")
        let stream = try #require(Self.firstView(UICollectionView.self, in: controller.view))
        // Comments land through a task; wait for the rows, not for a clock.
        let expected = 1 + entries.count
        var attempts = 0
        while stream.numberOfItems(inSection: 0) != expected, attempts < 500 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        stream.layoutIfNeeded()
        return (controller, stream, window)
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    @Test func commentsFromSeveralDaysShareTheOneSection() async throws {
        let (_, stream, _) = try await makeStream(Self.spreadAcrossDays)
        #expect(stream.numberOfSections == 1)
        #expect(stream.numberOfItems(inSection: 0) == 4, "the caption, then the three comments")
    }

    @Test func eachCommentRowCarriesItsOwnMenuAndTheStreamCarriesNone() async throws {
        let (_, stream, _) = try await makeStream(Self.spreadAcrossDays)
        let cell = try #require(stream.cellForItem(at: IndexPath(item: 1, section: 0)) as? CommentCell)
        #expect(cell.row.interactions.contains { $0 is UIContextMenuInteraction })
        #expect(!stream.interactions.contains { $0 is UIContextMenuInteraction })
    }

    @Test func theEngagedFooterCapsTheViewAndInsetsTheStream() async throws {
        let (controller, stream, _) = try await makeStream(Self.spreadAcrossDays)
        controller.setEngagedInsets(top: 120, bottomInset: 34)
        // Within half a point: fractional-scale CGFloats do not compare
        // exactly (the value read back printed as 96.0 and still failed `==`).
        #expect(abs(stream.contentInset.top - 120) < 0.5)
        #expect(abs(stream.contentInset.bottom - (34 + 62)) < 0.5)
        let topTwo = controller.view.subviews.suffix(2)
        #expect(topTwo.first is ProgressiveFrostView, "the footer's frost sits under the composer")
        #expect(topTwo.last is CommentsInputBar, "the composer caps the view")
    }
}
