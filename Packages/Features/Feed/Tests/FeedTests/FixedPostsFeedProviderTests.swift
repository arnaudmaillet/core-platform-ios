import CoreModels
import CoreNetworking
import Foundation
import Testing
@testable import Feed

struct FixedPostsFeedProviderTests {
    @Test func loadFirstPagePreservesRequestedOrder() async throws {
        let base = StubBase(entries: [
            "a": entry("a"), "b": entry("b"), "c": entry("c")
        ])
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("c"), PostID("a"), PostID("b")])

        let page = try await provider.loadFirstPage()

        #expect(page.entries.map(\.post.id) == [PostID("c"), PostID("a"), PostID("b")])
        #expect(page.nextPageToken == nil) // fixed set → never paginates
    }

    @Test func dropsPostsThatFailToHydrateWithoutFailingThePage() async throws {
        // "b" is GONE (not found) → it's skipped, rather than blanking the
        // whole feed.
        let base = StubBase(entries: ["a": entry("a"), "c": entry("c")])
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("a"), PostID("b"), PostID("c")])

        let page = try await provider.loadFirstPage()

        #expect(page.entries.map(\.post.id) == [PostID("a"), PostID("c")])
    }

    @Test func secondPageIsAlwaysEmpty() async throws {
        let base = StubBase(entries: ["a": entry("a")])
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("a")])

        let page = try await provider.loadPage(afterToken: "anything")

        #expect(page.entries.isEmpty)
        #expect(page.nextPageToken == nil)
    }

    /// Re-aiming is what lets the screen above be reused instead of rebuilt —
    /// the next load serves the NEW set, in the new order, with nothing of the
    /// old one left behind.
    @Test func repointServesTheNewWindowOnTheNextLoad() async throws {
        let base = StubBase(entries: [
            "a": entry("a"), "b": entry("b"), "c": entry("c")
        ])
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("a"), PostID("b")])
        #expect(try await provider.loadFirstPage().entries.map(\.post.id)
                == [PostID("a"), PostID("b")])

        await provider.repoint(to: [PostID("c"), PostID("a")])

        let page = try await provider.loadFirstPage()
        #expect(page.entries.map(\.post.id) == [PostID("c"), PostID("a")])
    }

    // MARK: - #1435: unread is not gone

    /// A post that failed for another reason than not-found is the copy the
    /// device holds, in its place.
    @Test func aTransientFailureKeepsThePostFromTheHeldCopy() async throws {
        let base = StubBase(
            entries: ["a": entry("a"), "c": entry("c")], failing: ["b"], held: ["b": entry("b")]
        )
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("a"), PostID("b"), PostID("c")])

        let page = try await provider.loadFirstPage()

        #expect(page.entries.map(\.post.id) == [PostID("a"), PostID("b"), PostID("c")])
    }

    /// With no copy, the window was not read — the load FAILS, so the feed
    /// keeps the page it shows rather than losing it.
    @Test func aTransientFailureWithNoCopyFailsTheLoad() async {
        let base = StubBase(entries: ["a": entry("a"), "c": entry("c")], failing: ["b"])
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("a"), PostID("b"), PostID("c")])

        await #expect(throws: (any Error).self) { try await provider.loadFirstPage() }
    }

    /// Offline: every read fails, and so does the load — never an empty page.
    @Test func anOfflineWindowFailsInsteadOfComingBackEmpty() async {
        let base = StubBase(entries: [:], failing: ["a", "b"])
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("a"), PostID("b")])

        await #expect(throws: (any Error).self) { try await provider.loadFirstPage() }
    }

    /// The feed on screen: seeded, its own first load offline — every seeded
    /// page and the opened post stay.
    @MainActor
    @Test func aSeededFeedKeepsItsPagesWhenItsFirstLoadIsOffline() async throws {
        let asks = Asks()
        let base = StubBase(entries: [:], failing: ["a", "b", "c"], asks: asks)
        let viewModel = FeedViewModel(
            repository: FixedPostsFeedProvider(base: base, ids: [PostID("a"), PostID("b"), PostID("c")])
        )
        var shown: [String] = []
        viewModel.onStateChange = { shown = $0.items.map(\.id.rawValue) }
        viewModel.seed(["a", "b", "c"].map {
            FeedItemDisplayModel(
                id: PostID($0), authorID: ProfileID("x"), authorName: "X", metaText: "", avatarURL: nil,
                caption: "", mediaURL: nil, mediaKind: .image, thumbnailURL: nil, audioText: nil
            )
        })
        viewModel.viewDidLoad()
        for _ in 0..<6_000 where asks.count < 3 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try #require(asks.count >= 3, "the first load never ran")
        // The load's answer lands a beat after its reads.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(shown == ["a", "b", "c"], "the seeded pages left the screen: \(shown)")
    }

    @Test func cachedFirstPageIsNil() async {
        let provider = FixedPostsFeedProvider(base: StubBase(entries: [:]), ids: [])
        #expect(await provider.cachedFirstPage() == nil)
    }

    // MARK: - Helpers

    private func entry(_ id: String) -> FeedEntry {
        FeedEntry(
            post: Post(id: PostID(id), authorID: ProfileID("author-\(id)"), caption: id, attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("author-\(id)"), handle: id, displayName: id, avatarURL: nil),
            likeCount: 0
        )
    }
}

/// Counts the reads, from any thread.
private final class Asks: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

private struct StubBase: FeedProviding {
    let entries: [String: FeedEntry]
    /// Reads that fail for another reason than not-found (offline).
    var failing: Set<String> = []
    /// The copies the device holds (`peekPost`).
    var held: [String: FeedEntry] = [:]
    var asks: Asks?

    func peekPost(_ id: PostID) -> FeedEntry? { held[id.rawValue] }

    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }

    func loadPost(_ id: PostID) async throws -> FeedEntry {
        asks?.add()
        if failing.contains(id.rawValue) {
            throw FeedError.transport(message: "offline", failure: .offline)
        }
        guard let entry = entries[id.rawValue] else { throw FeedError.notFound }
        return entry
    }
}
