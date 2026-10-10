import CoreContracts
import Foundation
import Testing
@testable import CoreRealtime
import CoreRealtimeMocks

private let fastConfig = RealtimeClient.Configuration(reconnectBaseDelay: 0.02, reconnectMaxDelay: 0.1)

private func makeClient(server: MockRealtimeServer, token: String = "edge-token") -> RealtimeClient {
    RealtimeClient(transport: server, tokenProvider: { token }, configuration: fastConfig)
}

/// Waits for `condition` to become true, polling; fails the test on timeout.
///
/// ⚠️ BOUNDED BY TRIES, NOT BY A CLOCK. Two seconds of wall time is a claim
/// about the machine, not about the work: CI runs every package's tests at
/// once, and the same budget that is a thousandfold margin on a quiet laptop
/// expires mid-test there — reported as the assertion failing, which reads
/// like a broken subscription and is nothing of the kind. The sibling helper in
/// `FeedEngagementTests` turned CI red exactly that way.
private func eventually(
    tries: Int = 1500,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<tries {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

struct RealtimeClientTests {
    @Test func subscribeDeliversEventsWithPayload() async throws {
        let server = MockRealtimeServer()
        let client = makeClient(server: server)
        let channel = RealtimeChannel.counter(entityID: "post-0001")

        let events = await client.events()
        await client.start()
        await client.subscribe(to: [channel])
        #expect(await eventually { server.isSubscribed(channel) })

        server.emitLikeCount(42, postID: "post-0001")

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.channel == channel)
        #expect(event?.eventType == "counter.update")
        let snapshot = try Counter_V1_CounterSnapshot(serializedBytes: try #require(event?.payload))
        #expect(snapshot.values.first?.value == 42)
        #expect(server.receivedTokens == ["edge-token"])

        await client.stop()
    }

    @Test func pingIsAnsweredWithEchoedNonce() async throws {
        let server = MockRealtimeServer()
        let client = makeClient(server: server)
        await client.start()
        #expect(await eventually { server.connectCount == 1 })

        server.sendPing(nonce: 777)

        #expect(await eventually { server.receivedPongNonces == [777] })
        await client.stop()
    }

    @Test func duplicateStreamSeqIsDeduped() async throws {
        let server = MockRealtimeServer()
        let client = makeClient(server: server)
        let channel = RealtimeChannel.counter(entityID: "post-0002")

        let events = await client.events()
        await client.start()
        await client.subscribe(to: [channel])
        #expect(await eventually { server.isSubscribed(channel) })

        server.emitLikeCount(1, postID: "post-0002") // seq 1
        server.emitLikeCount(2, postID: "post-0002") // seq 2

        var received: [UInt64] = []
        var iterator = events.makeAsyncIterator()
        for _ in 0..<2 {
            if let event = await iterator.next() {
                received.append(event.streamSeq)
            }
        }
        #expect(received == [1, 2])
        await client.stop()
    }

    @Test func dropTriggersReconnectWithResumeCursors() async throws {
        let server = MockRealtimeServer()
        let client = makeClient(server: server)
        let channel = RealtimeChannel.counter(entityID: "post-0003")

        let events = await client.events()
        let connections = await client.connectionEvents()
        await client.start()
        await client.subscribe(to: [channel])
        #expect(await eventually { server.isSubscribed(channel) })

        // Deliver two events so the client's cursor advances to 2.
        server.emitLikeCount(10, postID: "post-0003")
        server.emitLikeCount(11, postID: "post-0003")
        var eventIterator = events.makeAsyncIterator()
        _ = await eventIterator.next()
        _ = await eventIterator.next()

        var connectionIterator = connections.makeAsyncIterator()
        #expect(await connectionIterator.next() == .connected(resumed: false))

        // Kill the connection mid-session.
        server.dropConnection()
        #expect(await connectionIterator.next() == .disconnected)

        // The client reconnects on its own and presents its cursors via Resume.
        #expect(await connectionIterator.next() == .connected(resumed: true))
        #expect(await eventually { server.connectCount == 2 })
        let resume = try #require(server.receivedResumes.first)
        #expect(resume.count == 1)
        #expect(resume.first?.streamSeq == 2)
        #expect(resume.first?.channel.key == "post-0003")

        // Live flow continues on the resumed channel with the next sequence.
        server.emitLikeCount(12, postID: "post-0003")
        let next = await eventIterator.next()
        #expect(next?.streamSeq == 3)

        await client.stop()
    }

    @Test func eventsBeforeSubscriptionAreNotDelivered() async throws {
        let server = MockRealtimeServer()
        let client = makeClient(server: server)
        await client.start()
        #expect(await eventually { server.connectCount == 1 })

        // Not subscribed to this channel: the plane drops it.
        server.emitLikeCount(5, postID: "post-9999")

        let channel = RealtimeChannel.counter(entityID: "post-0004")
        let events = await client.events()
        await client.subscribe(to: [channel])
        #expect(await eventually { server.isSubscribed(channel) })
        server.emitLikeCount(7, postID: "post-0004")

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.channel.key == "post-0004")

        await client.stop()
    }
}

/// The mock network is down (#790): the server refuses the socket, as a real
/// one finds no route, and lets it back when the network returns.
@Test func aRefusingServerRejectsConnectionsUntilItAcceptsAgain() async throws {
    let server = MockRealtimeServer()
    server.refusesConnections = true
    await #expect(throws: URLError.self) {
        _ = try await server.connect(edgeToken: "edge-token")
    }
    server.refusesConnections = false
    _ = try await server.connect(edgeToken: "edge-token")
    #expect(server.connectCount == 1)
}

/// A socket that opens and dies at once, saying nothing — an offline device.
private final class DyingTransport: RealtimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var connects = 0
    var connectCount: Int { lock.withLock { connects } }

    func connect(edgeToken: String) async throws -> AsyncStream<RealtimeTransportEvent> {
        lock.withLock { connects += 1 }
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeTransportEvent.self)
        continuation.yield(.connected)
        continuation.yield(.disconnected(reason: "no route"))
        continuation.finish()
        return stream
    }

    func send(_ data: Data) async throws {}
    func disconnect() async {}
}

/// ⚠️ THE BACKOFF GROWS WHILE NOTHING ANSWERS (#792): a connection that dies
/// before the server says a word is a failed attempt, not a reset.
@Test func aConnectionThatNeverHearsTheServerKeepsBackingOff() async throws {
    let transport = DyingTransport()
    let client = RealtimeClient(transport: transport, tokenProvider: { "edge-token" }, configuration: fastConfig)
    await client.start()
    var tries = 0
    while transport.connectCount < 4, tries < 2_000 {
        tries += 1
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(transport.connectCount >= 4, "the client stopped reconnecting")
    #expect(await client.debugReconnectAttempt >= 3, "the backoff was reset by connections that never answered")
    await client.stop()
}
