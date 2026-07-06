import CoreContracts
import CoreRealtime
import Foundation

/// In-process fake of the realtime gateway: a `RealtimeTransport` that
/// implements the server side of the realtime.v1 frame protocol. Faithful to
/// the contract where it matters for clients: subscriptions are per-connection
/// (a reconnect must Subscribe/Resume again), events carry monotonic
/// `stream_seq` per channel, and nothing is buffered across connections.
public final class MockRealtimeServer: RealtimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var client: AsyncStream<RealtimeTransportEvent>.Continuation?
    private var subscribed: Set<RealtimeChannel> = []
    private var sequences: [RealtimeChannel: UInt64] = [:]

    // Test observation points.
    private var resumes: [[Realtime_V1_ChannelCursor]] = []
    private var pongNonces: [UInt64] = []
    private var connects = 0
    private var tokens: [String] = []

    public init() {}

    public var connectCount: Int { lock.withLock { connects } }
    public var receivedTokens: [String] { lock.withLock { tokens } }
    public var receivedResumes: [[Realtime_V1_ChannelCursor]] { lock.withLock { resumes } }
    public var receivedPongNonces: [UInt64] { lock.withLock { pongNonces } }
    public func isSubscribed(_ channel: RealtimeChannel) -> Bool {
        lock.withLock { subscribed.contains(channel) }
    }

    // MARK: - RealtimeTransport (client side calls these)

    public func connect(edgeToken: String) async throws -> AsyncStream<RealtimeTransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeTransportEvent.self)
        lock.withLock {
            connects += 1
            tokens.append(edgeToken)
            subscribed = [] // per-connection state; nothing survives a drop
            client = continuation
        }
        continuation.yield(.connected)
        return stream
    }

    public func send(_ data: Data) async throws {
        guard let frame = try? Realtime_V1_ClientFrame(serializedBytes: data), let body = frame.body else {
            return
        }
        switch body {
        case .subscribe(let subscribe):
            for ref in subscribe.channels {
                let channel = RealtimeChannel(channelClass: ref.class, key: ref.key)
                lock.withLock { _ = subscribed.insert(channel) }
                emitControl(.subscribed, channel: ref)
            }
        case .resume(let resume):
            lock.withLock {
                resumes.append(resume.cursors)
                for cursor in resume.cursors {
                    let channel = RealtimeChannel(channelClass: cursor.channel.class, key: cursor.channel.key)
                    subscribed.insert(channel)
                    sequences[channel] = max(sequences[channel] ?? 0, cursor.streamSeq)
                }
            }
        case .unsubscribe(let unsubscribe):
            lock.withLock {
                for ref in unsubscribe.channels {
                    subscribed.remove(RealtimeChannel(channelClass: ref.class, key: ref.key))
                }
            }
        case .pong(let pong):
            lock.withLock { pongNonces.append(pong.nonce) }
        case .ack, .authRefresh:
            break
        }
    }

    public func disconnect() async {
        dropConnection()
    }

    // MARK: - Server-side drivers (tests and demo mode)

    /// Emits a domain event on `channel` with the next stream_seq. Silently
    /// dropped if the client isn't subscribed on the current connection —
    /// exactly like the real plane.
    public func emit(payload: Data, eventType: String, on channel: RealtimeChannel, ackRequired: Bool = false) {
        let (continuation, sequence): (AsyncStream<RealtimeTransportEvent>.Continuation?, UInt64) = lock.withLock {
            guard subscribed.contains(channel) else { return (nil, 0) }
            let next = (sequences[channel] ?? 0) + 1
            sequences[channel] = next
            return (client, next)
        }
        guard let continuation else { return }

        var event = Realtime_V1_Event()
        event.channel = channel.ref
        event.streamSeq = sequence
        event.ackRequired = ackRequired
        event.payload = payload
        event.eventType = eventType
        var frame = Realtime_V1_ServerFrame()
        frame.body = .event(event)
        if let data = try? frame.serializedData() {
            continuation.yield(.message(data))
        }
    }

    /// Convenience for the COUNTER channel payload convention: a serialized
    /// counter.v1.CounterSnapshot with the LIKE metric, event_type "counter.update".
    public func emitLikeCount(_ count: Int64, postID: String) {
        var entity = Counter_V1_EntityRef()
        entity.entityType = .post
        entity.id = postID
        var value = Counter_V1_CounterValue()
        value.metric = .like
        value.value = count
        value.kind = .exact
        var snapshot = Counter_V1_CounterSnapshot()
        snapshot.entity = entity
        snapshot.values = [value]

        guard let payload = try? snapshot.serializedData() else { return }
        emit(payload: payload, eventType: "counter.update", on: .counter(entityID: postID))
    }

    private func emitControl(_ directive: Realtime_V1_ServerControl, channel: Realtime_V1_ChannelRef) {
        var control = Realtime_V1_Control()
        control.control = directive
        control.channel = channel
        var frame = Realtime_V1_ServerFrame()
        frame.body = .control(control)
        if let data = try? frame.serializedData(), let client = lock.withLock({ client }) {
            client.yield(.message(data))
        }
    }

    public func sendPing(nonce: UInt64) {
        var ping = Realtime_V1_Ping()
        ping.nonce = nonce
        var frame = Realtime_V1_ServerFrame()
        frame.body = .ping(ping)
        if let data = try? frame.serializedData(), let client = lock.withLock({ client }) {
            client.yield(.message(data))
        }
    }

    /// Kills the current connection (network blip / node reap). The client is
    /// expected to reconnect and Resume.
    public func dropConnection() {
        let continuation = lock.withLock {
            let current = client
            client = nil
            subscribed = []
            return current
        }
        continuation?.yield(.disconnected(reason: "server dropped connection"))
        continuation?.finish()
    }
}
