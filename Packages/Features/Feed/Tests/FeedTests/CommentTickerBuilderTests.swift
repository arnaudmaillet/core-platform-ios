import CoreModels
import Foundation
import Testing
@testable import Feed

private func entry(_ id: String, _ body: String) -> CommentEntry {
    CommentEntry(
        id: id,
        authorID: ProfileID("prof-1"),
        authorName: "Ava",
        authorHandle: "ava",
        body: body,
        createdAt: Date(timeIntervalSince1970: 1000)
    )
}

private func shortEntries(_ count: Int) -> [CommentEntry] {
    (0..<count).map { entry("c\($0)", "Nice one \($0)") }
}

struct CommentTickerBuilderTests {
    private let builder = CommentTickerBuilder()

    @Test func hidesBandBelowMinimumGate() {
        let sparse = builder.build(shortEntries(CommentTickerBuilder.minTickerCount - 1), postID: PostID("post-1"))
        #expect(sparse.isEmpty)

        let dense = builder.build(shortEntries(CommentTickerBuilder.minTickerCount), postID: PostID("post-1"))
        #expect(dense.count == CommentTickerBuilder.minTickerCount)
    }

    @Test func gateCountsOnlyQualifyingComments() {
        // 5 short + 3 disqualified: the gate must see 5, not 8.
        let entries = shortEntries(5) + [
            entry("long", String(repeating: "x", count: CommentTickerBuilder.maxCharacterCount + 1)),
            entry("multiline", "two\nlines"),
            entry("dupe", "Nice one 0"),
        ]
        #expect(builder.build(entries, postID: PostID("post-1")).isEmpty)
    }

    @Test func filtersLongMultilineDuplicateAndBlankBodies() {
        let entries = shortEntries(6) + [
            entry("long", String(repeating: "x", count: 200)),
            entry("multiline", "first\nsecond"),
            entry("dupe-case", "NICE ONE 0"), // case-insensitive duplicate
            entry("blank", "   \n  "),
        ]
        let queue = builder.build(entries, postID: PostID("post-1"))
        let ids = Set(queue.map(\.id))
        #expect(queue.count == 6)
        #expect(ids.isDisjoint(with: ["long", "multiline", "dupe-case", "blank"]))
    }

    @Test func trimsWhitespaceAndMeasuresTrimmedLength() {
        // Raw body exceeds the threshold only through padding; it qualifies
        // and the queue carries the trimmed text.
        let padded = "  " + String(repeating: "y", count: CommentTickerBuilder.maxCharacterCount) + "   "
        let entries = shortEntries(5) + [entry("padded", padded)]
        let queue = builder.build(entries, postID: PostID("post-1"))
        #expect(queue.count == 6)
        #expect(queue.first { $0.id == "padded" }?.text == String(repeating: "y", count: CommentTickerBuilder.maxCharacterCount))
    }

    @Test func capsQueueAtMaxItems() {
        let queue = builder.build(shortEntries(CommentTickerBuilder.maxItems + 10), postID: PostID("post-1"))
        #expect(queue.count == CommentTickerBuilder.maxItems)
    }

    @Test func queueIsDeterministicPerPostAndVariesAcrossPosts() {
        let entries = shortEntries(12)
        let first = builder.build(entries, postID: PostID("post-1"))
        let again = CommentTickerBuilder().build(entries, postID: PostID("post-1"))
        #expect(first == again) // same post → identical stream, across instances

        let other = builder.build(entries, postID: PostID("post-2"))
        #expect(Set(first.map(\.id)) == Set(other.map(\.id)))
        #expect(first != other) // different seed → different mix (deterministic, so stable to assert)
    }
}

// MARK: - View-model seam

private final class StubFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { throw FeedError.transport(message: "unused") }
    func loadPage(afterToken token: String) async throws -> FeedPage { throw FeedError.transport(message: "unused") }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "unused") }
}

private final class FakeCommentsProvider: CommentsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let comments: [CommentEntry]
    private var loadCount = 0

    init(comments: [CommentEntry]) { self.comments = comments }

    var loads: Int { lock.withLock { loadCount } }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] {
        lock.withLock {
            loadCount += 1
            return comments
        }
    }

    func addComment(_ body: String, to postID: PostID) async throws -> CommentEntry {
        throw CommentsError.transport(message: "unused")
    }
}

@MainActor
struct FeedViewModelTickerTests {
    private func awaitTickerEmission(_ viewModel: FeedViewModel, activating id: PostID) async -> (PostID, [TickerCommentModel]) {
        await withCheckedContinuation { continuation in
            viewModel.onTickerCommentsChange = { id, comments in
                viewModel.onTickerCommentsChange = nil
                continuation.resume(returning: (id, comments))
            }
            viewModel.pageDidBecomeActive(id)
        }
    }

    @Test func activationLoadsBuildsAndCachesTheQueue() async {
        let provider = FakeCommentsProvider(comments: shortEntries(8))
        let viewModel = FeedViewModel(repository: StubFeedProvider(), commentsProvider: provider)
        let id = PostID("post-0042")

        let (emittedID, queue) = await awaitTickerEmission(viewModel, activating: id)
        #expect(emittedID == id)
        #expect(queue.count == 8)
        #expect(viewModel.tickerComments(for: id) == queue)

        // Re-activation re-emits the cached queue without another load.
        let (_, again) = await awaitTickerEmission(viewModel, activating: id)
        #expect(again == queue)
        #expect(provider.loads == 1)
    }

    @Test func gatedPostEmitsEmptyQueue() async {
        let provider = FakeCommentsProvider(comments: shortEntries(3))
        let viewModel = FeedViewModel(repository: StubFeedProvider(), commentsProvider: provider)

        let (_, queue) = await awaitTickerEmission(viewModel, activating: PostID("post-0001"))
        #expect(queue.isEmpty)
    }
}
