import Testing
@testable import CoreModels

/// A scripted server: page `n` is asked with token `"t\(n)"` (the first with
/// ""), holds `[n]`, and hands back the next token until `pages` ran out.
/// Records every token it was asked with.
private actor ScriptedPages {
    let pages: Int
    let failingAt: Int?
    private(set) var asked: [String] = []

    init(pages: Int, failingAt: Int? = nil) {
        self.pages = pages
        self.failingAt = failingAt
    }

    func page(_ token: String) throws -> (items: [Int], nextPageToken: String) {
        asked.append(token)
        let index = token.isEmpty ? 0 : Int(token.dropFirst())!
        if index == failingAt { throw PageFailure(index: index) }
        let next = index + 1 < pages ? "t\(index + 1)" : ""
        return ([index], next)
    }
}

private struct PageFailure: Error, Equatable {
    let index: Int
}

struct TokenPagerTests {
    @Test func stopsOnTheFirstEmptyToken() async throws {
        let server = ScriptedPages(pages: 3)
        let items = try await TokenPager.collect(maxPages: 20) { try await server.page($0) }
        #expect(items == [0, 1, 2])
        #expect(await server.asked == ["", "t1", "t2"])
    }

    @Test func aSinglePageListIsOneRead() async throws {
        let server = ScriptedPages(pages: 1)
        let items = try await TokenPager.collect(maxPages: 20) { try await server.page($0) }
        #expect(items == [0])
        #expect(await server.asked == [""])
    }

    @Test func honoursTheCap() async throws {
        // A server that never ends the list: the cap is what stops the read.
        let server = ScriptedPages(pages: 1_000)
        let items = try await TokenPager.collect(maxPages: 2) { try await server.page($0) }
        #expect(items == [0, 1])
        #expect(await server.asked == ["", "t1"])
    }

    @Test func aCapOfZeroReadsNothing() async throws {
        let server = ScriptedPages(pages: 3)
        let items = try await TokenPager.collect(maxPages: 0) { try await server.page($0) }
        #expect(items.isEmpty)
        #expect(await server.asked.isEmpty)
    }

    @Test func propagatesTheFetchErrorAndStops() async {
        let server = ScriptedPages(pages: 5, failingAt: 1)
        await #expect(throws: PageFailure(index: 1)) {
            _ = try await TokenPager.collect(maxPages: 20) { try await server.page($0) }
        }
        #expect(await server.asked == ["", "t1"])
    }

    @Test func neverAsksForTheSamePageTwice() async throws {
        let server = ScriptedPages(pages: 6)
        _ = try await TokenPager.collect(maxPages: 20) { try await server.page($0) }
        let asked = await server.asked
        #expect(asked.count == 6)
        #expect(Set(asked).count == asked.count)
    }

    @Test func aFetchThatCannotThrowNeedsNoTry() async {
        // `rethrows`: a non-throwing fetch makes a non-throwing read.
        var served = 0
        let items = await TokenPager.collect(maxPages: 20) { token -> (items: [String], nextPageToken: String) in
            served += 1
            return ([token], served < 3 ? "next\(served)" : "")
        }
        #expect(items == ["", "next1", "next2"])
    }
}
