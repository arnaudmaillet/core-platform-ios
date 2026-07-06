import CoreContracts
import Foundation
import OSLog

/// The client side of the realtime.v1 WSS protocol: one multiplexed
/// connection carrying every channel class.
///
/// Contract obligations implemented here:
/// - dedupe and cursor-tracking on `stream_seq` per channel;
/// - `ClientAck` for ack-required (at-least-once) events;
/// - `Pong` echoing every `Ping` nonce;
/// - `Resume` with the last-seen cursors on every reconnect;
/// - reconnect backoff with **mandatory jitter** (herd avoidance);
/// - `AuthRefresh` on REAUTH_REQUIRED without dropping the connection.
///
/// The plane buffers nothing: consumers must treat
/// `.connected(resumed: true)` as the cue to reconcile state against the
/// owning service (e.g. re-read counters).
public actor RealtimeClient {
    public nonisolated struct Configuration: Sendable {
        public var reconnectBaseDelay: TimeInterval
        public var reconnectMaxDelay: TimeInterval

        public init(reconnectBaseDelay: TimeInterval = 0.5, reconnectMaxDelay: TimeInterval = 15) {
            self.reconnectBaseDelay = reconnectBaseDelay
            self.reconnectMaxDelay = reconnectMaxDelay
        }
    }

    private let transport: any RealtimeTransport
    private let tokenProvider: @Sendable () async throws -> String?
    private let configuration: Configuration
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "realtime")

    private var running = false
    private var isConnected = false
    private var hasConnectedBefore = false
    private var loopTask: Task<Void, Never>?

    private var desiredChannels: Set<RealtimeChannel> = []
    private var cursors: [RealtimeChannel: UInt64] = [:]

    private var eventObservers: [UUID: AsyncStream<RealtimeEvent>.Continuation] = [:]
    private var connectionObservers: [UUID: AsyncStream<RealtimeConnectionEvent>.Continuation] = [:]

    public init(
        transport: any RealtimeTransport,
        tokenProvider: @escaping @Sendable () async throws -> String?,
        configuration: Configuration
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        loopTask = Task { await runConnectionLoop() }
    }

    public func stop() async {
        running = false
        loopTask?.cancel()
        loopTask = nil
        await transport.disconnect()
        if isConnected {
            isConnected = false
            broadcastConnection(.disconnected)
        }
    }

    // MARK: - Subscriptions

    public func subscribe(to channels: Set<RealtimeChannel>) async {
        let new = channels.subtracting(desiredChannels)
        guard !new.isEmpty else { return }
        desiredChannels.formUnion(new)
        if isConnected {
            await sendSubscribe(Array(new))
        }
    }

    public func unsubscribe(from channels: Set<RealtimeChannel>) async {
        desiredChannels.subtract(channels)
        guard isConnected else { return }
        var unsubscribe = Realtime_V1_Unsubscribe()
        unsubscribe.channels = channels.map(\.ref)
        var frame = Realtime_V1_ClientFrame()
        frame.body = .unsubscribe(unsubscribe)
        await send(frame)
    }

    // MARK: - Observation

    public func events() -> AsyncStream<RealtimeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventObserver(id) }
        }
        eventObservers[id] = continuation
        return stream
    }

    public func connectionEvents() -> AsyncStream<RealtimeConnectionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeConnectionEvent.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeConnectionObserver(id) }
        }
        connectionObservers[id] = continuation
        return stream
    }

    // MARK: - Connection loop

    private func runConnectionLoop() async {
        var attempt = 0
        while running, !Task.isCancelled {
            do {
                guard let token = try await tokenProvider() else {
                    // Unauthenticated; retry once auth may exist.
                    try await sleepWithJitter(attempt: attempt)
                    attempt += 1
                    continue
                }

                let stream = try await transport.connect(edgeToken: token)
                receive: for await transportEvent in stream {
                    guard running else { break receive }
                    switch transportEvent {
                    case .connected:
                        attempt = 0
                        isConnected = true
                        let resumed = hasConnectedBefore
                        hasConnectedBefore = true
                        await announceChannels()
                        broadcastConnection(.connected(resumed: resumed))
                    case .message(let data):
                        await handleServerFrame(data)
                    case .disconnected(let reason):
                        logger.info("realtime disconnected: \(reason ?? "eof")")
                        break receive
                    }
                }
            } catch {
                logger.error("realtime connect failed: \(error)")
            }

            if isConnected {
                isConnected = false
                broadcastConnection(.disconnected)
            }
            guard running, !Task.isCancelled else { break }
            attempt += 1
            try? await sleepWithJitter(attempt: attempt)
        }
    }

    /// Resume channels we hold cursors for; plain-subscribe the rest.
    private func announceChannels() async {
        let resumable = desiredChannels.filter { cursors[$0, default: 0] > 0 }
        if !resumable.isEmpty {
            var resume = Realtime_V1_Resume()
            resume.cursors = resumable.map { channel in
                var cursor = Realtime_V1_ChannelCursor()
                cursor.channel = channel.ref
                cursor.streamSeq = cursors[channel] ?? 0
                return cursor
            }
            var frame = Realtime_V1_ClientFrame()
            frame.body = .resume(resume)
            await send(frame)
        }
        let fresh = desiredChannels.subtracting(resumable)
        if !fresh.isEmpty {
            await sendSubscribe(Array(fresh))
        }
    }

    // MARK: - Inbound frames

    private func handleServerFrame(_ data: Data) async {
        guard let frame = try? Realtime_V1_ServerFrame(serializedBytes: data), let body = frame.body else {
            logger.error("undecodable server frame (\(data.count) bytes)")
            return
        }

        switch body {
        case .event(let event):
            let channel = RealtimeChannel(ref: event.channel)
            guard event.streamSeq > cursors[channel, default: 0] else {
                return // duplicate or replay; dedupe on stream_seq per contract
            }
            cursors[channel] = event.streamSeq
            if event.ackRequired {
                var ack = Realtime_V1_ClientAck()
                ack.channel = event.channel
                ack.streamSeq = event.streamSeq
                var frame = Realtime_V1_ClientFrame()
                frame.body = .ack(ack)
                await send(frame)
            }
            let realtimeEvent = RealtimeEvent(
                channel: channel,
                streamSeq: event.streamSeq,
                eventType: event.eventType,
                payload: event.payload
            )
            for continuation in eventObservers.values {
                continuation.yield(realtimeEvent)
            }

        case .ping(let ping):
            var pong = Realtime_V1_Pong()
            pong.nonce = ping.nonce
            var frame = Realtime_V1_ClientFrame()
            frame.body = .pong(pong)
            await send(frame)

        case .control(let control):
            await handleControl(control)
        }
    }

    private func handleControl(_ control: Realtime_V1_Control) async {
        switch control.control {
        case .reauthRequired:
            if let token = try? await tokenProvider() {
                var refresh = Realtime_V1_AuthRefresh()
                refresh.edgeToken = token
                var frame = Realtime_V1_ClientFrame()
                frame.body = .authRefresh(refresh)
                await send(frame)
            }
        case .reconnect:
            // Server-directed move (node drain). Base delay is the server's;
            // our loop adds the mandatory jitter on reconnect.
            logger.info("server requested reconnect in \(control.reconnectAfterMs)ms")
            try? await Task.sleep(nanoseconds: UInt64(control.reconnectAfterMs) * 1_000_000)
            await transport.disconnect()
        case .error, .rateLimited:
            logger.error("realtime control \(control.code): \(control.message)")
        case .subscribed, .unsubscribed, .unspecified, .UNRECOGNIZED:
            break
        }
    }

    // MARK: - Outbound helpers

    private func sendSubscribe(_ channels: [RealtimeChannel]) async {
        var subscribe = Realtime_V1_Subscribe()
        subscribe.channels = channels.map(\.ref)
        var frame = Realtime_V1_ClientFrame()
        frame.body = .subscribe(subscribe)
        await send(frame)
    }

    private func send(_ frame: Realtime_V1_ClientFrame) async {
        do {
            try await transport.send(frame.serializedData())
        } catch {
            logger.error("realtime send failed: \(error)")
        }
    }

    private func sleepWithJitter(attempt: Int) async throws {
        let exponential = configuration.reconnectBaseDelay * pow(2, Double(max(0, attempt - 1)))
        let capped = min(exponential, configuration.reconnectMaxDelay)
        let jittered = capped * Double.random(in: 0.5...1.5)
        try await Task.sleep(nanoseconds: UInt64(jittered * 1_000_000_000))
    }

    private func broadcastConnection(_ event: RealtimeConnectionEvent) {
        for continuation in connectionObservers.values {
            continuation.yield(event)
        }
    }

    private func removeEventObserver(_ id: UUID) {
        eventObservers[id] = nil
    }

    private func removeConnectionObserver(_ id: UUID) {
        connectionObservers[id] = nil
    }
}
