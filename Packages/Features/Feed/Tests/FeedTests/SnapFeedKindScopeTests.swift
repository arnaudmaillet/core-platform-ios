import CoreModels
import FeedInterface
import Foundation
import PostGrid
import Testing
@testable import Feed

// One kind per vertical feed (#1421): the opening post's.

/// "m…" ids are media posts (one attachment), "t…" ids text posts; "x…" ids
/// do not hydrate.
private final class KindHydrating: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        if id.rawValue.hasPrefix("x") { throw FeedError.transport(message: "gone") }
        let media = id.rawValue.hasPrefix("m")
            ? [MediaAttachment(url: URL(string: "https://cdn.example/\(id.rawValue).mp4"), thumbnailURL: nil,
                               mimeType: "video/mp4", pixelWidth: 720, pixelHeight: 1280)]
            : []
        return FeedEntry(
            post: Post(id: id, authorID: ProfileID("p"), caption: id.rawValue, attachments: media,
                       publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }
}

/// A source answering "what follows `after`" from a script, recording asks.
@MainActor
private final class Script {
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
private func served(_ page: FeedPage) -> [String] { page.entries.map(\.post.id.rawValue) }

@MainActor
struct SnapFeedKindScopeTests {
    private func provider(
        _ window: [PostID], _ script: Script? = nil, complete: Bool = false
    ) -> FixedPostsFeedProvider {
        FixedPostsFeedProvider(
            base: KindHydrating(), ids: window, continuation: script?.continuation,
            isCompleteSet: complete, keepsToOpeningKind: true
        )
    }

    /// Opened on a media post: the window keeps its media, the opening post
    /// first.
    @Test func aMediaOpeningKeepsMediaOnly() async throws {
        let page = try await provider(ids("m1", "t1", "m2", "t2", "m3"), complete: true).loadFirstPage()
        #expect(served(page) == ["m1", "m2", "m3"])
    }

    /// Opened on a text post: text only.
    @Test func aTextOpeningKeepsTextOnly() async throws {
        let page = try await provider(ids("t1", "m1", "t2", "m2"), complete: true).loadFirstPage()
        #expect(served(page) == ["t1", "t2"])
    }

    /// A complete set filtered to its opening post alone shows that one post,
    /// and is the end.
    @Test func aCompleteSetFilteredToOnePostShowsIt() async throws {
        let page = try await provider(ids("t1", "m1", "m2"), complete: true).loadFirstPage()
        #expect(served(page) == ["t1"])
        #expect(page.isEndOfSource)
        #expect(page.nextPageToken == nil)
    }

    /// Every continuation page keeps to the kind too.
    @Test func continuationPagesKeepTheKind() async throws {
        let script = Script()
        script.next["t1"] = ids("m1", "t2", "t3", "m2", "t4", "t5", "t6")
        script.next["t6"] = ids("t7")
        script.next["t7"] = nil
        let feed = provider(ids("t1"), script)
        let first = try await feed.loadFirstPage()
        // A short first window is filled from the source.
        #expect(served(first) == ["t1", "t2", "t3", "t4", "t5", "t6"])
        #expect(first.nextPageToken != nil)
        let next = try await feed.loadPage(afterToken: FixedPostsFeedProvider.continuationToken)
        #expect(served(next) == ["t7"])
        #expect(next.isEndOfSource, "the source ended after t7")
    }

    /// ⚠️ SHORT PAGES DO NOT READ AS THE END: a source whose next steps hold
    /// none of this kind is asked again, up to the bound, rather than the
    /// feed stopping while the source has more.
    @Test func aRunOfTheOtherKindIsWalkedThrough() async throws {
        let script = Script()
        script.next["t1"] = ids("m1", "m2")
        script.next["m2"] = ids("m3")
        script.next["m3"] = ids("t2", "m4")
        script.next["m4"] = nil
        let feed = provider(ids("t1"), script)
        let first = try await feed.loadFirstPage()
        #expect(served(first) == ["t1", "t2"], "the text post past the media run was not reached")
        #expect(first.isEndOfSource)
    }

    /// Nothing of the kind within the bound, and the source not over: the
    /// next page throws, so the feed keeps its token and asks again later.
    @Test func nothingOfTheKindYetKeepsTheToken() async throws {
        let script = Script()
        var step = "t1"
        for index in 0..<(FixedPostsFeedProvider.maxFillRounds * 2 + 2) {
            let id = "m\(index)"
            script.next[step] = [PostID(id)]
            step = id
        }
        let feed = provider(ids("t1"), script)
        let first = try await feed.loadFirstPage()
        #expect(served(first) == ["t1"])
        #expect(first.nextPageToken != nil, "a short window read as the end")
        await #expect(throws: FeedContinuationError.self) {
            _ = try await feed.loadPage(afterToken: FixedPostsFeedProvider.continuationToken)
        }
    }

    /// A reused feed re-reads the kind off its new opening post (For You's
    /// repoint): a text opening after a media one gives text.
    @Test func aRepointReadsTheKindAgain() async throws {
        let feed = provider(ids("m1", "t1", "m2"))
        #expect(served(try await feed.loadFirstPage()) == ["m1", "m2"])
        await feed.repoint(to: ids("t2", "m3", "t3"))
        #expect(served(try await feed.loadFirstPage()) == ["t2", "t3"])
        #expect(await feed.scope == .text)
    }

    /// The opening post did not hydrate: no scope, nothing filtered — never
    /// an empty feed for a reason the viewer cannot see.
    @Test func anUnhydratedOpeningFiltersNothing() async throws {
        let page = try await provider(ids("x1", "m1", "t1"), complete: true).loadFirstPage()
        #expect(served(page) == ["m1", "t1"])
    }

    /// The pre-push seed keeps to the opening post's kind too, so a page the
    /// viewer reaches before the fetch lands is never taken away by it.
    @Test func theSeedKeepsTheOpeningKind() {
        func post(_ id: String, text: Bool) -> GalleryPost {
            GalleryPost(
                id: PostID(id), kind: text ? .text : .photo, isRepost: false,
                thumbnailURL: text ? nil : URL(string: "https://cdn.example/\(id).jpg"),
                caption: id, publishedAtMS: 0
            )
        }
        let media = GalleryPostProjection.seedModels(from: [post("m1", text: false), post("t1", text: true), post("m2", text: false)])
        #expect(SnapFeedViewController.keepingOpeningKind(media).map(\.id.rawValue) == ["m1", "m2"])
        let text = GalleryPostProjection.seedModels(from: [post("t1", text: true), post("m1", text: false), post("t2", text: true)])
        #expect(SnapFeedViewController.keepingOpeningKind(text).map(\.id.rawValue) == ["t1", "t2"])
    }

    /// A hydration helper (a place's or a search surface's posts) is not a
    /// vertical feed: it serves every kind.
    @Test func aHydrationHelperKeepsEveryKind() async throws {
        let helper = FixedPostsFeedProvider(base: KindHydrating(), ids: ids("m1", "t1"))
        #expect(served(try await helper.loadFirstPage()) == ["m1", "t1"])
    }
}
