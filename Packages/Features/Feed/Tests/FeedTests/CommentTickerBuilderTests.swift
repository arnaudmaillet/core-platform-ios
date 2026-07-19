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
        // 5 short + 4 disqualified: the gate must see 5, not 9.
        let entries = shortEntries(5) + [
            entry("long", String(repeating: "x", count: CommentTickerBuilder.maxCharacterCount + 1)),
            entry("multiline", "two\nlines"),
            entry("dupe", "Nice one 0"),
            entry("phrase", "how is this so good"), // within chars, past the word cap
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

    @Test func emojiRelaxesTheWordCapButPlainPhrasesAreRejected() {
        let entries = shortEntries(5) + [
            entry("emoji-run", "🔥🔥🔥"),
            entry("emoji-phrase", "so good 😭 fr fr"), // >3 words, emoji-borne → rides
            entry("vs16-emoji", "love this ❤️"), // text-default scalar forced emoji (U+FE0F)
            entry("plain-phrase", "how is this so good"), // >3 words, no emoji → sheet
        ]
        let queue = builder.build(entries, postID: PostID("post-1"))
        let ids = Set(queue.map(\.id))
        #expect(ids.isSuperset(of: ["emoji-run", "emoji-phrase", "vs16-emoji"]))
        #expect(!ids.contains("plain-phrase"))
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

    func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
        throw CommentsError.transport(message: "unused")
    }
}

@MainActor
struct FeedViewModelStreamsTests {
    private func awaitStreamsEmission(_ viewModel: FeedViewModel, activating id: PostID) async -> (PostID, FeedViewModel.CommentStreams) {
        await withCheckedContinuation { continuation in
            viewModel.onCommentStreamsChange = { id, streams in
                viewModel.onCommentStreamsChange = nil
                continuation.resume(returning: (id, streams))
            }
            viewModel.pageDidBecomeActive(id)
        }
    }

    @Test func activationLoadsBuildsAndCachesTheStreams() async {
        let provider = FakeCommentsProvider(comments: shortEntries(8))
        let viewModel = FeedViewModel(repository: StubFeedProvider(), commentsProvider: provider)
        let id = PostID("post-0042")

        let (emittedID, streams) = await awaitStreamsEmission(viewModel, activating: id)
        #expect(emittedID == id)
        #expect(streams.reactions.count == 8)
        #expect(streams.subtitles.isEmpty) // all short bodies — nothing semantic
        #expect(streams.commentCount == 8) // raw total, before any surface filter
        #expect(viewModel.commentStreams(for: id) == streams)

        // Re-activation re-emits the cached streams without another load.
        let (_, again) = await awaitStreamsEmission(viewModel, activating: id)
        #expect(again == streams)
        #expect(provider.loads == 1)
    }

    /// One fetch feeds both surfaces: mixed comments partition into the
    /// band's queue and the zone's cues with no overlap.
    @Test func mixedCommentsPartitionIntoBothStreams() async {
        let semantic = (0..<3).map { entry("sem\($0)", "This is a longer thought number \($0) worth reading.") }
        let provider = FakeCommentsProvider(comments: shortEntries(6) + semantic)
        let viewModel = FeedViewModel(repository: StubFeedProvider(), commentsProvider: provider)

        let (_, streams) = await awaitStreamsEmission(viewModel, activating: PostID("post-0042"))
        #expect(streams.reactions.count == 6)
        #expect(streams.subtitles.count == 3)
        #expect(streams.commentCount == 9)
        #expect(Set(streams.reactions.map(\.id)).isDisjoint(with: streams.subtitles.map(\.id)))
        #expect(provider.loads == 1)
    }

    /// Both surfaces gate below their minimums, but `commentCount` is a
    /// post fact, not a surface artifact — it carries the true total even
    /// when nothing renders (the hidden zone never shows it).
    @Test func gatedPostEmitsEmptySurfacesButTheTrueCount() async {
        let provider = FakeCommentsProvider(comments: shortEntries(3))
        let viewModel = FeedViewModel(repository: StubFeedProvider(), commentsProvider: provider)

        let (_, streams) = await awaitStreamsEmission(viewModel, activating: PostID("post-0001"))
        #expect(streams.reactions.isEmpty)
        #expect(streams.subtitles.isEmpty)
        #expect(streams.commentCount == 3)
        #expect(streams.isLoaded)
    }

    /// A post the backend answers with NO comments at all loads as
    /// KNOWN-zero: `isLoaded` is what separates it from the pre-load
    /// `.empty` sentinel (otherwise value-identical), and it is the seam
    /// the chrome's "No comments yet" empty state renders on — never
    /// while a fetch is still in flight.
    @Test func zeroCommentPostLoadsAsKnownZero() async {
        let provider = FakeCommentsProvider(comments: [])
        let viewModel = FeedViewModel(repository: StubFeedProvider(), commentsProvider: provider)
        let id = PostID("post-0009")

        #expect(FeedViewModel.CommentStreams.empty.isLoaded == false)
        #expect(viewModel.commentStreams(for: id).isLoaded == false)

        let (_, streams) = await awaitStreamsEmission(viewModel, activating: id)
        #expect(streams.isLoaded)
        #expect(streams.commentCount == 0)
        #expect(streams.reactions.isEmpty)
        #expect(streams.subtitles.isEmpty)
        #expect(streams != .empty)
        #expect(viewModel.commentStreams(for: id) == streams)
    }
}
