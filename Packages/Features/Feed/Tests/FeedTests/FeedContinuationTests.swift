import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

// A full-screen feed opened from a tile, going on into the source (#638).

/// Hydrates every id except those it is told are gone.
private final class Hydrating: FeedProviding, @unchecked Sendable {
    let gone: Set<String>
    init(gone: Set<String> = []) { self.gone = gone }

    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        if gone.contains(id.rawValue) { throw FeedError.transport(message: "gone") }
        return FeedEntry(
            post: Post(id: id, authorID: ProfileID("p"), caption: id.rawValue, attachments: [],
                       publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }
}

/// A source answering "what follows `after`" from a script, recording asks.
@MainActor
private final class Source {
    var next: [String: [PostID]?] = [:]
    private(set) var asks: [String] = []

    var continuation: SnapFeedContinuation {
        { [self] after in
            asks.append(after.rawValue)
            return next[after.rawValue] ?? nil
        }
    }
}

private func ids(_ raw: String...) -> [PostID] { raw.map { PostID($0) } }

@MainActor
struct FeedContinuationTests {
    // MARK: - The provider

    @Test func aFeedWithAContinuationGoesOnIntoTheSourceUntilItEnds() async throws {
        let source = Source()
        source.next = ["b": ids("c", "d"), "d": nil]
        let provider = FixedPostsFeedProvider(base: Hydrating(), ids: ids("a", "b"), continuation: source.continuation)

        let first = try await provider.loadFirstPage()
        #expect(first.entries.map(\.post.id.rawValue) == ["a", "b"])
        let token = try #require(first.nextPageToken)

        let second = try await provider.loadPage(afterToken: token)
        #expect(second.entries.map(\.post.id.rawValue) == ["c", "d"])
        let again = try #require(second.nextPageToken)

        let end = try await provider.loadPage(afterToken: again)
        #expect(end.entries.isEmpty)
        #expect(end.nextPageToken == nil)
        #expect(source.asks == ["b", "d"])
    }

    /// A window with no continuation is the whole set, as before.
    @Test func aFeedWithoutAContinuationIsItsWindow() async throws {
        let provider = FixedPostsFeedProvider(base: Hydrating(), ids: ids("a", "b"))

        let first = try await provider.loadFirstPage()

        #expect(first.entries.count == 2)
        #expect(first.nextPageToken == nil)
    }

    /// Nothing right now (a failed page) keeps the feed's place: the step
    /// throws, the feed keeps its token, and the next approach asks the same
    /// question again.
    @Test func nothingYetKeepsThePlaceForTheNextApproach() async throws {
        let source = Source()
        source.next = ["b": []]
        let provider = FixedPostsFeedProvider(base: Hydrating(), ids: ids("a", "b"), continuation: source.continuation)
        let token = try #require(try await provider.loadFirstPage().nextPageToken)

        await #expect(throws: FeedContinuationError.self) { try await provider.loadPage(afterToken: token) }

        source.next = ["b": ids("c")]
        let retried = try await provider.loadPage(afterToken: token)
        #expect(retried.entries.map(\.post.id.rawValue) == ["c"])
        #expect(source.asks == ["b", "b"])
    }

    /// Posts that all fail to hydrate bring no row to ask again: the next
    /// step is taken at once.
    @Test func aStepThatHydratesNothingMovesStraightOn() async throws {
        let source = Source()
        source.next = ["b": ids("x"), "x": ids("c"), "c": nil]
        let provider = FixedPostsFeedProvider(
            base: Hydrating(gone: ["x"]), ids: ids("a", "b"), continuation: source.continuation
        )
        let token = try #require(try await provider.loadFirstPage().nextPageToken)

        let page = try await provider.loadPage(afterToken: token)

        #expect(page.entries.map(\.post.id.rawValue) == ["c"])
        #expect(source.asks == ["b", "x"])
    }

    /// A re-aimed window (For You's reused feed) is a whole set.
    @Test func repointingDropsTheContinuation() async throws {
        let source = Source()
        source.next = ["b": ids("c")]
        let provider = FixedPostsFeedProvider(base: Hydrating(), ids: ids("a", "b"), continuation: source.continuation)

        await provider.repoint(to: ids("z"))
        let first = try await provider.loadFirstPage()

        #expect(first.nextPageToken == nil)
    }

    // MARK: - The shared grid continuation (For You's lists and Discover)

    @Test func aGridHandsOnWhatItHoldsThenAsksItsCaller() async {
        var held = ids("a", "b")
        var more = true
        var asks = 0
        let continuation = GridFeedContinuation(
            ids: { held }, hasMore: { more }, askMore: { asks += 1 }
        )

        #expect(await continuation.postIDs(after: PostID("a")) == ids("b"))

        // At its end, the grid asks; the caller's page lands and is answered.
        let pending = Task { await continuation.postIDs(after: PostID("b")) }
        await settleUntil { asks == 1 }
        held = ids("a", "b", "c")
        more = false
        continuation.answered()
        #expect(await pending.value == ids("c"))

        // The end: nothing more, said at once.
        #expect(await continuation.postIDs(after: PostID("c")) == nil)
        #expect(asks == 1)
    }

    /// An answer that brings nothing (a failed page) is "nothing yet".
    @Test func aGridAnswerWithNothingNewIsNothingYet() async {
        var asks = 0
        let continuation = GridFeedContinuation(
            ids: { ids("a") }, hasMore: { true }, askMore: { asks += 1 }
        )
        let pending = Task { await continuation.postIDs(after: PostID("a")) }
        await settleUntil { asks == 1 }
        continuation.answered()
        await settleUntil { asks == 2 }
        continuation.answered()

        #expect(await pending.value == [])
    }

    /// Looks, not wall-clock time — see the Profile suites' note (#636).
    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - A search/hashtag surface as the source

    private func makeSurface(showing shown: [PostID]) -> PostSetSurfaceViewController {
        let surface = PostSetSurfaceViewController(
            style: .gallery,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            hydrate: { _ in [] }
        )
        surface.show(.posts(shown))
        return surface
    }

    @Test func theSurfaceHandsOnWhatItHoldsPastTheWindow() async {
        let all = (0..<20).map { PostID("p\($0)") }
        let surface = makeSurface(showing: all)

        let next = await surface.postIDs(after: PostID("p3"))

        #expect(next == Array(all[4..<16]))
    }

    @Test func atTheEndWithNothingMoreTheSourceSaysSo() async {
        let surface = makeSurface(showing: ids("a", "b"))
        surface.setHasMore(false)

        #expect(await surface.postIDs(after: PostID("b")) == nil)
    }

    /// At the end of what it holds, with more to come, the surface asks its
    /// caller for the next page and hands on what that page brings.
    @Test func atTheEndTheSurfaceAsksItsCallerForTheNextPage() async {
        let surface = makeSurface(showing: ids("a", "b"))
        surface.setHasMore(true)
        var asked = 0
        surface.onNearEnd = { [weak surface] in
            asked += 1
            // The caller's next page lands a moment later.
            Task { @MainActor in
                surface?.show(.posts(ids("a", "b", "c", "d")))
                surface?.setHasMore(false)
            }
        }

        let next = await surface.postIDs(after: PostID("b"))

        #expect(next == ids("c", "d"))
        #expect(asked == 1)
    }

    /// A page that fails ends the paging without growing the list: the feed
    /// hears "nothing yet" and asks again on its next approach.
    @Test func aFailedPageIsNothingYet() async {
        let surface = makeSurface(showing: ids("a", "b"))
        surface.setHasMore(true)
        surface.onNearEnd = { [weak surface] in
            Task { @MainActor in
                surface?.setPaging(true)
                surface?.setPaging(false)
            }
        }

        #expect(await surface.postIDs(after: PostID("b")) == [])
    }
}
