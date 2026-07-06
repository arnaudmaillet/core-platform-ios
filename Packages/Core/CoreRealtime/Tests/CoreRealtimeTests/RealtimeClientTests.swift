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
private func eventually(
    timeout: TimeInterval = 2,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
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
