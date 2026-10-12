import CacheKit
import Foundation
import Testing
@testable import LocalStore

/// Conversations' newest messages on the device (#897): the 50 × 200 bounds,
/// cold-start reads, paging cursors, merges with live items, expiry, budget
/// and the viewer wipe.
final class LocalStoreTranscriptTests {
    private let folder = TemporaryFolder()
    private let viewer = ViewerBox(alice)
    private let clock = ManualCacheClock()

    private func open(limit: Int = .max) throws -> LocalStore {
        try LocalStore.test(
            in: folder, viewer: viewer, clock: clock, limits: CacheLimits(bytes: limit, speculativeBytes: limit)
        )
    }

    /// Message `index`: id `m007`, sorted by its index.
    private func message(_ index: Int, _ text: String? = nil) -> LocalTranscriptItem {
        LocalTranscriptItem(
            id: String(format: "m%03d", index), sortKey: Int64(index), payload: Data((text ?? "message \(index)").utf8)
        )
    }

    /// Messages `range` as one page, `cursor` fetching what is older.
    private func messages(_ range: ClosedRange<Int>, cursor: String?) -> LocalTranscriptPage {
        LocalTranscriptPage(items: range.reversed().map { message($0) }, olderCursor: cursor)
    }

    private func itemIDs(_ transcript: LocalTranscript?) -> [String] {
        transcript?.items.map(\.id) ?? []
    }

    private func ids(_ range: ClosedRange<Int>) -> [String] {
        range.map { String(format: "m%03d", $0) }
    }

    // MARK: - Reads and cursors

    @Test func aColdStartReadsTheNewestMessagesOldestFirstWithTheirCursor() throws {
        do {
            let store = try open()
            #expect(try store.storeNewest(messages(150...199, cursor: "c150"), in: "conv-1", as: alice))
        }
        let reopened = try open()
        let transcript = try #require(reopened.transcript("conv-1"))
        #expect(itemIDs(transcript) == ids(150...199))
        #expect(transcript.olderCursor == "c150", "paging older goes on from the stored cursor")
        #expect(String(decoding: transcript.items[0].payload, as: UTF8.self) == "message 150")
        #expect(reopened.transcript("conv-2") == nil)
    }

    @Test func anOlderPageGoesBelowAndOnlyAfterTheStoredCursor() throws {
        let store = try open()
        try store.storeNewest(messages(150...199, cursor: "c150"), in: "conv-1", as: alice)
        #expect(try !store.storeOlder(messages(50...99, cursor: "c50"), in: "conv-1", after: "c100", as: alice),
                "a page that does not follow what is stored is not stored")
        #expect(try store.storeOlder(messages(100...149, cursor: "c100"), in: "conv-1", after: "c150", as: alice))
        let transcript = try #require(store.transcript("conv-1"))
        #expect(itemIDs(transcript) == ids(100...199))
        #expect(transcript.olderCursor == "c100")
        // The start of the conversation: nothing older to page.
        #expect(try store.storeOlder(messages(90...99, cursor: nil), in: "conv-1", after: "c100", as: alice))
        #expect(store.transcript("conv-1")?.olderCursor == nil)
        #expect(try !store.storeOlder(messages(0...10, cursor: nil), in: "conv-2", after: "c0", as: alice),
                "nothing stored for that conversation: nothing to page below")
    }

    @Test func aNewestPageOverlappingTheStoredOnesIsMergedOverThem() throws {
        let store = try open()
        try store.storeNewest(messages(150...199, cursor: "c150"), in: "conv-1", as: alice)
        try store.storeOlder(messages(100...149, cursor: "c100"), in: "conv-1", after: "c150", as: alice)
        // Five new messages; m190 went away (the server no longer serves it).
        var fresh = messages(155...204, cursor: "c155")
        fresh.items.removeAll { $0.id == "m190" }
        #expect(try store.storeNewest(fresh, in: "conv-1", as: alice))
        let transcript = try #require(store.transcript("conv-1"))
        #expect(itemIDs(transcript) == ids(100...204).filter { $0 != "m190" })
        #expect(transcript.olderCursor == "c100", "the older pages and their cursor stay")
    }

    @Test func aNewestPageWithAGapBehindItReplacesTheStoredOnes() throws {
        let store = try open()
        try store.storeNewest(messages(150...199, cursor: "c150"), in: "conv-1", as: alice)
        // Days later: fifty new messages, none of them stored.
        #expect(try store.storeNewest(messages(300...349, cursor: "c300"), in: "conv-1", as: alice))
        let transcript = try #require(store.transcript("conv-1"))
        #expect(itemIDs(transcript) == ids(300...349), "no hole between the stored runs")
        #expect(transcript.olderCursor == "c300")
    }

    @Test func aPageThatReachesTheStartIsTheWholeConversation() throws {
        let store = try open()
        try store.storeNewest(messages(0...9, cursor: nil), in: "conv-1", as: alice)
        var fresh = messages(0...10, cursor: nil)
        fresh.items.removeAll { $0.id == "m003" }
        try store.storeNewest(fresh, in: "conv-1", as: alice)
        #expect(itemIDs(store.transcript("conv-1")) == ids(0...10).filter { $0 != "m003" })
        // An empty conversation is stored too: it opens on "no messages yet".
        try store.storeNewest(LocalTranscriptPage(items: [], olderCursor: nil), in: "conv-2", as: alice)
        let empty = try #require(store.transcript("conv-2"))
        #expect(empty.items.isEmpty)
        #expect(empty.olderCursor == nil)
    }

    // MARK: - Live items

    @Test func aSentMessageThenThePageCarryingItIsOneRow() throws {
        let store = try open()
        try store.storeNewest(messages(150...199, cursor: "c150"), in: "conv-1", as: alice)
        // The viewer's message, timed by the device.
        #expect(try store.insertLive([LocalTranscriptItem(id: "m200", sortKey: 205, payload: Data("sent".utf8))], in: "conv-1", as: alice))
        #expect(itemIDs(store.transcript("conv-1")).last == "m200")
        // The next load carries it, timed by the server.
        try store.storeNewest(LocalTranscriptPage(items: (151...200).map { message($0, $0 == 200 ? "served" : nil) }, olderCursor: "c151"), in: "conv-1", as: alice)
        let transcript = try #require(store.transcript("conv-1"))
        #expect(transcript.items.filter { $0.id == "m200" }.count == 1)
        #expect(transcript.items.last.map { String(decoding: $0.payload, as: UTF8.self) } == "served")
        #expect(transcript.items.last?.sortKey == 200)
        #expect(try store.rowCount("transcript_item") == 51)
    }

    @Test func aLiveMessageNeedsAStoredTranscript() throws {
        let store = try open()
        #expect(try !store.insertLive([message(1)], in: "conv-1", as: alice), "a lone message says nothing of what is older")
        #expect(store.transcript("conv-1") == nil)
        // An empty conversation's first message is its start.
        try store.storeNewest(LocalTranscriptPage(items: [], olderCursor: nil), in: "conv-2", as: alice)
        #expect(try store.insertLive([message(1)], in: "conv-2", as: alice))
        let transcript = try #require(store.transcript("conv-2"))
        #expect(itemIDs(transcript) == ["m001"])
        #expect(transcript.olderCursor == nil)
    }

    // MARK: - Bounds

    @Test func aTranscriptKeepsItsNewest200CutBackToAPageBoundary() throws {
        let store = try open()
        try store.storeNewest(messages(250...299, cursor: "c250"), in: "conv-1", as: alice)
        try store.storeOlder(messages(200...249, cursor: "c200"), in: "conv-1", after: "c250", as: alice)
        try store.storeOlder(messages(150...199, cursor: "c150"), in: "conv-1", after: "c200", as: alice)
        try store.storeOlder(messages(100...149, cursor: "c100"), in: "conv-1", after: "c150", as: alice)
        #expect(store.transcript("conv-1")?.items.count == 200)
        #expect(try !store.storeOlder(messages(50...99, cursor: "c50"), in: "conv-1", after: "c100", as: alice),
                "full: older messages page from the network")

        // Ten new messages: 210 would be stored. The newest 200 run back to
        // m110, which no cursor goes on from; the last boundary within them
        // is m150's page.
        try store.storeNewest(messages(260...309, cursor: "c260"), in: "conv-1", as: alice)
        let transcript = try #require(store.transcript("conv-1"))
        #expect(itemIDs(transcript) == ids(150...309))
        #expect(transcript.olderCursor == "c150")
        #expect(try store.rowCount("transcript_item") == 160)
    }

    @Test func theLast50ConversationsAreKeptTheLeastRecentlyOpenedGoesFirst() throws {
        let store = try open()
        for index in 1...50 {
            try store.storeNewest(messages(0...2, cursor: nil), in: "conv-\(index)", as: alice)
            clock.advance(by: 1)
        }
        #expect(try store.rowCount("transcript") == 50)
        // Opening conv-1 again makes conv-2 the least recently opened.
        #expect(store.transcript("conv-1") != nil)
        store.waitForPendingWrites()
        clock.advance(by: 1)
        try store.storeNewest(messages(0...2, cursor: nil), in: "conv-51", as: alice)
        #expect(try store.rowCount("transcript") == 50)
        #expect(store.transcript("conv-2") == nil, "the least recently opened went")
        #expect(store.transcript("conv-1") != nil)
        #expect(store.transcript("conv-51") != nil)
        #expect(try store.rowCount("transcript_item") == 150, "its messages went with it")
        #expect(store.statistics.evictions >= 1)
    }

    @Test func aTranscriptExpiresAfter30Days() throws {
        let store = try open()
        try store.storeNewest(messages(0...9, cursor: nil), in: "conv-1", as: alice)
        clock.advance(by: LocalStorePolicy.transcriptLifetime - 60)
        #expect(store.transcript("conv-1") != nil)
        clock.advance(by: 120)
        #expect(store.transcript("conv-1") == nil)
        store.trim(.expired)
        store.waitForPendingWrites()
        #expect(try store.rowCount("transcript") == 0)
        #expect(try store.rowCount("transcript_item") == 0)
    }

    // MARK: - Budget

    @Test func transcriptsCountAsRetainedAndABudgetTakesTheLeastRecentlyOpened() throws {
        let store = try open()
        let big = Data(repeating: 1, count: 10_000)
        for index in 1...3 {
            let page = LocalTranscriptPage(
                items: (0..<5).map { LocalTranscriptItem(id: "m\($0)", sortKey: Int64($0), payload: big) }, olderCursor: nil
            )
            try store.storeNewest(page, in: "conv-\(index)", as: alice)
            clock.advance(by: 1)
        }
        let usage = store.usage
        #expect(usage.bytesByTier[.retained] == usage.bytes)
        #expect(usage.bytes > 150_000)
        #expect(usage.count == 15)

        // Room for two conversations.
        store.setLimits(CacheLimits(bytes: 110_000, speculativeBytes: 110_000))
        store.waitForPendingWrites()
        #expect(store.transcript("conv-1") == nil, "the least recently opened went first")
        #expect(store.transcript("conv-2") != nil)
        #expect(store.transcript("conv-3") != nil)
        // A memory trim below `retained` leaves them alone.
        store.trim(.belowRetained)
        store.waitForPendingWrites()
        #expect(store.transcript("conv-3") != nil)
        store.trim(.allButPinned)
        store.waitForPendingWrites()
        #expect(try store.rowCount("transcript") == 0)
    }

    // MARK: - Viewers

    @Test func anotherViewerReadsNoneOfTheMessagesAndTheyAreWiped() throws {
        let store = try open()
        try store.storeNewest(messages(0...9, cursor: nil), in: "conv-1", as: alice)
        #expect(store.transcript("conv-1") != nil)
        viewer.viewer = bob
        #expect(store.transcript("conv-1") == nil)
        store.waitForPendingWrites()
        #expect(try store.rowCount("transcript") == 0)
        #expect(try store.rowCount("transcript_item") == 0)
        // A page fetched for alice that lands after the switch is dropped.
        #expect(try !store.storeNewest(messages(0...9, cursor: nil), in: "conv-1", as: alice))
        #expect(store.transcript("conv-1") == nil)
    }

    @Test func aLogoutWipesTheMessages() throws {
        let store = try open()
        try store.storeNewest(messages(0...9, cursor: nil), in: "conv-1", as: alice)
        store.removeAll()
        #expect(store.transcript("conv-1") == nil)
        store.waitForPendingWrites()
        #expect(try store.rowCount("transcript_item") == 0)
    }

    // MARK: - Bounded lists

    @Test func aBoundedListStopsStoringPagesAtItsBound() throws {
        let store = try open()
        try store.replaceList("notifications", with: page((0..<20).map { "n\($0)" }, cursor: "c20"), as: alice)
        for start in stride(from: 20, to: 100, by: 20) {
            let next = page((start..<start + 20).map { "n\($0)" }, cursor: "c\(start + 20)", tier: .recent)
            #expect(try store.appendPage(next, to: "notifications", after: "c\(start)", as: alice, maxEntries: 100))
        }
        let beyond = page((100..<120).map { "n\($0)" }, cursor: "c120", tier: .recent)
        #expect(try !store.appendPage(beyond, to: "notifications", after: "c100", as: alice, maxEntries: 100))
        let list = try #require(store.list("notifications"))
        #expect(list.entries.count == 100)
        #expect(list.nextCursor == "c100", "paging goes on from the network where the stored pages stop")
    }
}
