import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A TEXT post's resting comments (`threadChrome: true`): threads grouped
/// under a pinned day pill in Recent order, one section in Trending, and the
/// long press owned by the stream.
///
/// The other side — a media post's panel, the pushed comments screen — is
/// `PostDetailStreamShapeTests`; together they pin both sides of the one
/// parameter.
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
        func addComment(
            _ body: String, to postID: PostID, parentID: String?, commentID: String
        ) async throws -> CommentEntry {
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
        _ entries: [CommentEntry], threadChrome: Bool = true, groupsByDay: Bool = false
    ) async throws -> (PostDetailViewController, UICollectionView, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: PostID("p"), repository: NoPostFeed(), commentsProvider: Prefetched(entries)
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .commentsOnly,
            threadChrome: threadChrome,
            groupsByDay: groupsByDay
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

    /// Many comments over three days: enough to scroll past the chips.
    private static let longAcrossDays: [CommentEntry] = (0..<36).map { index in
        entry("l\(index)", ageInDays: Double(index / 12) * 1.1 + Double(index % 12) * 0.01)
    }

    /// ⚠️ A MEDIA POST'S COMMENTS GROUP BY DAY TOO (#757): every snap page's
    /// panel, not only a text page's.
    @Test func aMediaPanelGroupsItsThreadsByDayToo() async throws {
        let (_, stream, window) = try await makeStream(Self.spreadAcrossDays, threadChrome: false, groupsByDay: true)
        defer { window.isHidden = true }
        #expect(stream.numberOfSections >= 3, "one section per day: \(stream.numberOfSections)")
    }

    /// ⚠️ THE DAY CHIPS ARE NOT STICKY (#757), and the panel tells its host
    /// the day of the last chip gone under its top — none before one has.
    @Test func theChipsScrollAwayAndTheDayUnderTheTopIsTold() async throws {
        let (controller, stream, window) = try await makeStream(Self.longAcrossDays)
        defer { window.isHidden = true }
        var told: [Date?] = []
        controller.onDayUnderHeaderChange = { told.append($0) }
        stream.setContentOffset(CGPoint(x: 0, y: -stream.adjustedContentInset.top), animated: false)
        stream.layoutIfNeeded()
        controller.debugSyncDayUnderHeader()
        #expect(controller.dayUnderHeader == nil, "a day before any chip went under the top")

        let bottom = stream.contentSize.height + stream.adjustedContentInset.bottom - stream.bounds.height
        stream.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        stream.layoutIfNeeded()
        controller.debugSyncDayUnderHeader()
        let day = try #require(controller.dayUnderHeader, "no day under the top at the end of the thread")
        #expect(told.last == day)

        // Not sticky: the first day's chip has scrolled away above the top.
        let firstChip = try #require((1..<stream.numberOfSections).lazy.compactMap {
            stream.layoutAttributesForSupplementaryElement(
                ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: $0)
            )
        }.first)
        #expect(firstChip.frame.maxY < stream.contentOffset.y + stream.adjustedContentInset.top,
                "the chip stayed pinned to the top: \(firstChip.frame)")
    }

    /// ⚠️ A TAP ON THE BAR'S DAY LANDS THAT DAY'S CHIP UNDER THE TOP (#757):
    /// the bar then still says the day it was tapped on, rather than the day
    /// before it, or nothing. Unanimated: a test window has no scene to drive
    /// the scroll's animation (the tap's wiring is `SnapCommentsDayBarTests`).
    @Test func scrollingToADayLandsItsChipUnderTheTop() async throws {
        let (controller, stream, window) = try await makeStream(Self.longAcrossDays)
        defer { window.isHidden = true }
        let days = controller.debugStreamDays
        try #require(days.count >= 3, "the premise: three days in the thread")

        // From the end of the thread, where the oldest day is under the top.
        let bottom = stream.contentSize.height + stream.adjustedContentInset.bottom - stream.bounds.height
        stream.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        stream.layoutIfNeeded()
        controller.debugSyncDayUnderHeader()
        #expect(controller.dayUnderHeader == days[days.count - 1].day, "the premise: the oldest day at the end")

        // The middle day: its chip is above the top here, the next one too.
        let target = days[1]
        let start = stream.contentOffset.y
        controller.scrollToDay(target.day, animated: false)
        stream.layoutIfNeeded()

        #expect(stream.contentOffset.y != start, "the tap scrolled nothing")
        let line = stream.contentOffset.y + stream.adjustedContentInset.top
        let chip = try #require(stream.layoutAttributesForSupplementaryElement(
            ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: target.section)
        ))
        #expect(chip.frame.midY <= line, "the chip landed below the top: \(chip.frame) against \(line)")
        let next = try #require(stream.layoutAttributesForSupplementaryElement(
            ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: days[2].section)
        ))
        #expect(next.frame.midY > line, "the scroll ran past the day: \(next.frame) against \(line)")
        // Told by the scroll itself, not by a re-read.
        #expect(controller.dayUnderHeader == target.day,
                "the bar's day after the tap: \(String(describing: controller.dayUnderHeader))")
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

    /// The count the sort waits on (`CommentSortPolicy`), as the stream holds it.
    @Test func theStreamReportsHowManyCommentsItHolds() async throws {
        let (controller, _, _) = try await makeStream(Self.spreadAcrossDays)

        #expect(controller.commentCount == 3)
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
