import Foundation

/// One-way bridge for locally-composed posts: the compose feature publishes a
/// freshly-created `FeedEntry`, the feed observes and prepends it optimistically.
///
/// This is deliberately a local channel, not the realtime FEED plane: your own
/// just-published post appears immediately without a server round-trip. It
/// keeps the two features decoupled — both depend on CoreModels, neither on
/// each other.
public actor ComposedPostChannel {
    private var observers: [UUID: AsyncStream<FeedEntry>.Continuation] = [:]

    public init() {}

    public func publish(_ entry: FeedEntry) {
        for continuation in observers.values {
            continuation.yield(entry)
        }
    }

    public func entries() -> AsyncStream<FeedEntry> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: FeedEntry.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = continuation
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
