import CoreContracts
import Foundation

/// A realtime channel: (class, key) per realtime.v1.ChannelRef. DM /
/// NOTIFICATION / PRESENCE keys must equal the connection's identity;
/// COUNTER / FEED keys are public entity ids.
public struct RealtimeChannel: Hashable, Sendable {
    public let channelClass: Realtime_V1_ChannelClass
    public let key: String

    public init(channelClass: Realtime_V1_ChannelClass, key: String) {
        self.channelClass = channelClass
        self.key = key
    }

    public static func counter(entityID: String) -> RealtimeChannel {
        RealtimeChannel(channelClass: .counter, key: entityID)
    }

    public init(ref: Realtime_V1_ChannelRef) {
        self.init(channelClass: ref.class, key: ref.key)
    }

    public var ref: Realtime_V1_ChannelRef {
        var ref = Realtime_V1_ChannelRef()
        ref.class = channelClass
        ref.key = key
        return ref
    }
}

/// A delivered domain event. `payload` is opaque to the realtime plane;
/// consumers decode it according to `eventType` (e.g. "counter.update"
/// carries a serialized counter.v1.CounterSnapshot).
public struct RealtimeEvent: Sendable {
    public let channel: RealtimeChannel
    public let streamSeq: UInt64
    public let eventType: String
    public let payload: Data

    public init(channel: RealtimeChannel, streamSeq: UInt64, eventType: String, payload: Data) {
        self.channel = channel
        self.streamSeq = streamSeq
        self.eventType = eventType
        self.payload = payload
    }
}

public enum RealtimeConnectionEvent: Equatable, Sendable {
    /// `resumed` is true on any connection after the first — the signal for
    /// consumers to reconcile against the owning source of record (the plane
    /// buffers nothing).
    case connected(resumed: Bool)
    case disconnected
}

// MARK: - Transport seam

public enum RealtimeTransportEvent: Sendable {
    case connected
    case message(Data)
    case disconnected(reason: String?)
}

/// The socket boundary: real WSS in production, `MockRealtimeServer`
/// in tests and mock mode. One `connect` call = one connection; the returned
/// stream finishes when that connection dies.
public protocol RealtimeTransport: Sendable {
    func connect(edgeToken: String) async throws -> AsyncStream<RealtimeTransportEvent>
    func send(_ data: Data) async throws
    func disconnect() async
}
