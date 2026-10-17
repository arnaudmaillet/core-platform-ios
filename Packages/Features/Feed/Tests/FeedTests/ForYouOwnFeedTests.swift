import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Feed

/// The vertical feed's own list (#1343, the owner 2026-10-17): from For You's
/// "For you" section or its gallery, the feed opens on the tapped post, then
/// posts read from the discovery pool on a cursor of its own — none the grid
/// already holds, and paging it never pages the grid.
@MainActor
struct ForYouOwnFeedTests {
    private final class Pool: ForYouProviding, @unchecked Sendable {
        var pages: [String: ForYouPage] = [:]
        private(set) var reads: [String] = []
        func firstPage() async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
        func page(after token: String) async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
        func discoveryFirstPage() async throws -> ForYouPage? {
            reads.append("")
            return pages[""]
        }
        func discoveryPage(after token: String) async throws -> ForYouPage? {
            reads.append(token)
            return pages[token]
        }
    }

    private static func post(_ id: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.test/\(id).jpg"),
            caption: id, publishedAtMS: 0
        )
    }

    private static func page(_ ids: [String], next: String?) -> ForYouPage {
        ForYouPage(posts: ids.map(post), nextPageToken: next)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// The tapped post, then the pool past the grid: the pool's head is the
    /// grid's, so its posts are skipped, not replayed.
    @Test func theFeedOpensOnTheTappedPostThenItsOwnPosts() async throws {
        let pool = Pool()
        pool.pages[""] = Self.page(["g1", "g2", "g3", "o1"], next: "t2")
        pool.pages["t2"] = Self.page(["g4", "o2", "o3"], next: "t3")
        let grid: Set<PostID> = ["g1", "g2", "g3", "g4"].reduce(into: []) { $0.insert(PostID($1)) }
        let feed = ForYouOwnFeed(repository: pool) { grid }

        feed.prepare()
        await settle { !feed.debugReadAhead.isEmpty }
        let window = try #require(feed.begin(with: Self.post("g2")))
        #expect(window.map(\.id.rawValue).first == "g2", "the feed did not open on the tapped post")
        let rest = window.dropFirst().map(\.id)
        #expect(!rest.isEmpty)
        #expect(rest.allSatisfy { !grid.contains($0) }, "the grid's posts were replayed: \(rest)")
    }

    /// Paging the feed reads ITS cursor on, never repeating a post it served.
    @Test func pagingTheFeedReadsItsOwnCursorOn() async throws {
        let pool = Pool()
        pool.pages[""] = Self.page(["o1", "o2"], next: "t2")
        pool.pages["t2"] = Self.page(["o2", "o3"], next: nil)
        let feed = ForYouOwnFeed(repository: pool) { [] }
        feed.prepare()
        await settle { !feed.debugReadAhead.isEmpty }
        let window = try #require(feed.begin(with: Self.post("tapped")))
        let served = Set(window.map(\.id))

        let next = await feed.next(after: window.last!.id) ?? []
        #expect(next.allSatisfy { !served.contains($0) }, "a served post came back: \(next)")
        #expect(await feed.next(after: PostID("o3")) == nil, "the spent pool did not end the feed")
    }

    /// No discovery (or nothing past the grid): no own list — the caller
    /// keeps the grid's window, as before.
    @Test func withNothingPastTheGridThereIsNoOwnList() async {
        let pool = Pool()
        pool.pages[""] = Self.page(["g1"], next: nil)
        let feed = ForYouOwnFeed(repository: pool) { [PostID("g1")] }
        feed.prepare()
        await settle { !pool.reads.isEmpty }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(feed.begin(with: Self.post("g1")) == nil)
    }

    /// ⚠️ THE NEXT OPENING CARRIES ON (filmed 2026-10-17): it used to start
    /// over and replay the same posts after the tapped one every time.
    @Test func theNextOpeningCarriesOnWhereTheLastStopped() async throws {
        let pool = Pool()
        pool.pages[""] = Self.page((0..<12).map { "a\($0)" }, next: "t2")
        pool.pages["t2"] = Self.page((0..<12).map { "b\($0)" }, next: "t3")
        pool.pages["t3"] = Self.page((0..<12).map { "c\($0)" }, next: nil)
        let feed = ForYouOwnFeed(repository: pool) { [] }
        feed.prepare()
        await settle { !feed.debugReadAhead.isEmpty }
        let first = try #require(feed.begin(with: Self.post("tap1")))
        feed.end()
        await settle { !feed.debugReadAhead.isEmpty }
        let second = try #require(feed.begin(with: Self.post("tap2")))
        let firstRest = Set(first.dropFirst().map(\.id))
        let secondRest = second.dropFirst().map(\.id)
        #expect(!secondRest.isEmpty)
        #expect(secondRest.allSatisfy { !firstRest.contains($0) }, "the second opening replayed the first: \(secondRest)")

        // A refresh starts the pool over.
        feed.reset()
        await settle { !feed.debugReadAhead.isEmpty }
        let third = try #require(feed.begin(with: Self.post("tap3")))
        #expect(third.dropFirst().first?.id.rawValue == "a0")
    }
}
