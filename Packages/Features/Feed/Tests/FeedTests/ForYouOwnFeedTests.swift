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
        /// Pages that throw (a timeout, offline) until taken out.
        var failing: Set<String> = []
        private(set) var reads: [String] = []
        func firstPage() async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
        func page(after token: String) async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
        func discoveryFirstPage() async throws -> ForYouPage? {
            reads.append("")
            if failing.contains("") { throw URLError(.timedOut) }
            return pages[""]
        }
        func discoveryPage(after token: String) async throws -> ForYouPage? {
            reads.append(token)
            if failing.contains(token) { throw URLError(.timedOut) }
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

    /// No discovery: no own list — the caller keeps the grid's window.
    @Test func withoutDiscoveryThereIsNoOwnList() {
        let feed = ForYouOwnFeed(repository: Pool(), isAvailable: { false }) { [] }
        #expect(feed.begin(with: Self.post("g1")) == nil)
    }

    /// ⚠️ A TAP BEFORE THE FIRST READ LANDS (filmed 2026-10-17): the feed
    /// opens on the tapped post alone — never the grid's order — and its
    /// continuation brings the own posts once read.
    @Test func aTapBeforeTheFirstReadStillOpensTheOwnList() async throws {
        let pool = Pool()
        pool.pages[""] = Self.page(["g1", "o1", "o2"], next: nil)
        let feed = ForYouOwnFeed(repository: pool) { [PostID("g1")] }
        let window = try #require(feed.begin(with: Self.post("g1")))
        #expect(window.map(\.id.rawValue) == ["g1"], "the grid's window came back")
        let next = await feed.next(after: PostID("g1"))
        #expect(next?.map(\.rawValue) == ["o1", "o2"])
        #expect(await feed.next(after: PostID("o2")) == nil)
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

    // MARK: - Only the server ends the list (#1496)

    /// ⚠️ AFTER THE END, A NEW PASS: every post served stayed served, and the
    /// next opening held the tapped post alone, at its end at once.
    @Test func anOpeningAfterTheEndStartsANewPass() async throws {
        let pool = Pool()
        pool.pages[""] = Self.page(["o1", "o2", "o3"], next: nil)
        let feed = ForYouOwnFeed(repository: pool) { [] }
        feed.prepare()
        await settle { !feed.debugReadAhead.isEmpty }
        let first = try #require(feed.begin(with: Self.post("tap1")))
        #expect(first.map(\.id.rawValue) == ["tap1", "o1", "o2", "o3"])
        #expect(await feed.next(after: PostID("o3")) == nil, "the true end is the end")
        feed.end()

        let second = try #require(feed.begin(with: Self.post("o2")))
        #expect(second.map(\.id.rawValue) == ["o2"], "the tapped post first")
        let rest = await feed.next(after: PostID("o2"))
        #expect(rest?.map(\.rawValue) == ["o1", "o3"], "the new pass is not the pool from its start: \(rest ?? [])")
    }

    /// While unseen posts remain, an opening still carries on (#1347): no
    /// new pass before the server has said "no more".
    @Test func anOpeningBeforeTheEndCarriesOn() async throws {
        let pool = Pool()
        // Pages of a window's size: one read stops at the first.
        pool.pages[""] = Self.page((0..<ForYouOwnFeed.windowSize).map { "a\($0)" }, next: "t2")
        pool.pages["t2"] = Self.page((0..<ForYouOwnFeed.windowSize).map { "b\($0)" }, next: nil)
        let feed = ForYouOwnFeed(repository: pool) { [] }
        feed.prepare()
        await settle { !feed.debugReadAhead.isEmpty }
        _ = try #require(feed.begin(with: Self.post("tap1")))
        feed.end()
        await settle { !feed.debugReadAhead.isEmpty }
        let second = try #require(feed.begin(with: Self.post("tap2")))
        #expect(second.dropFirst().first?.id.rawValue == "b0", "the opening started over")
    }

    /// ⚠️ A FAILED PAGE IS NOT THE END: one timeout used to end the list
    /// until a refresh. It answers "nothing yet", and the next ask reads the
    /// same page again.
    @Test func aFailedPageNeverEndsTheFeed() async throws {
        let pool = Pool()
        pool.pages[""] = Self.page(["o1"], next: "t2")
        pool.pages["t2"] = Self.page(["o2"], next: nil)
        let feed = ForYouOwnFeed(repository: pool) { [] }
        let window = try #require(feed.begin(with: Self.post("tap")))
        #expect(window.map(\.id.rawValue) == ["tap"])
        #expect(await feed.next(after: PostID("tap"))?.map(\.rawValue) == ["o1", "o2"])

        let failing = Pool()
        failing.pages[""] = Self.page(["o1"], next: "t2")
        failing.pages["t2"] = Self.page(["o2"], next: nil)
        failing.failing = ["t2"]
        let other = ForYouOwnFeed(repository: failing) { [] }
        _ = try #require(other.begin(with: Self.post("tap")))
        #expect(await other.next(after: PostID("tap"))?.map(\.rawValue) == ["o1"])
        let blip = await other.next(after: PostID("o1"))
        #expect(blip == [], "a failed page ended the feed: \(String(describing: blip))")
        failing.failing = []
        #expect(await other.next(after: PostID("o1"))?.map(\.rawValue) == ["o2"], "the retry did not read the same page")
        #expect(await other.next(after: PostID("o2")) == nil)
    }

    /// Excluded pages with a token left are "nothing yet", not the end: the
    /// read gave up after its page bound while the server still had more.
    @Test func excludedPagesWithATokenNeverEndTheFeed() async throws {
        let pool = Pool()
        // More excluded pages than the read ahead and one more read can page
        // through together: the first ask comes back empty-handed.
        let excludedPages = 2 * ForYouOwnFeed.maxPagesPerRead + 1
        for index in 0..<excludedPages {
            let token = index == 0 ? "" : "t\(index)"
            pool.pages[token] = Self.page(["g\(index)"], next: "t\(index + 1)")
        }
        pool.pages["t\(excludedPages)"] = Self.page(["o1"], next: nil)
        let grid = Set((0..<excludedPages).map { PostID("g\($0)") })
        let feed = ForYouOwnFeed(repository: pool) { grid }
        _ = try #require(feed.begin(with: Self.post("tap")))
        let short = await feed.next(after: PostID("tap"))
        #expect(short == [], "the page bound ended the feed: \(String(describing: short))")
        #expect(await feed.next(after: PostID("tap"))?.map(\.rawValue) == ["o1"])
        #expect(await feed.next(after: PostID("o1")) == nil)
    }
}
