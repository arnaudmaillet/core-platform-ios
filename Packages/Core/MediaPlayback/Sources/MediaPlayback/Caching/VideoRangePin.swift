import CacheKit
import Foundation
import Synchronization

/// A hold on the cached ranges of one file around a playhead (#895, the #923
/// follow-up): what a parked return player will read when a close resumes it.
///
/// A player's own loader pins only what it has served, and a parked return
/// player has served little: its seek, one decoded frame. The bytes around
/// the tile's playhead were written by the tile's player, whose leases end
/// when the page that took that player is retired. Without a pin, a budget cut
/// while the post is open could drop exactly the ranges the close needs, and
/// the resumed clip would stall on the network.
///
/// Released by its owner (the return ledger) when the player is claimed,
/// released or evicted, and by `deinit`. The entries then keep their tier: a
/// played head stays `retained`, everything else is `recent` (a lease also
/// promotes a `speculative` head), and the store's LRU order takes over.
public final class VideoRangePin: Sendable {
    private let state = Mutex<(released: Bool, leases: [CacheLease])>((false, []))

    init() {}

    /// Takes leases made on the cache's queue. A pin already released lets
    /// them go at once: a release that overtook the pinning wins.
    func adopt(_ leases: [CacheLease]) {
        let late = state.withLock { state -> [CacheLease] in
            guard !state.released else { return leases }
            state.leases += leases
            return []
        }
        for lease in late { lease.release() }
    }

    /// Lets every range go. Idempotent.
    public func release() {
        let held = state.withLock { state -> [CacheLease] in
            state.released = true
            let taken = state.leases
            state.leases = []
            return taken
        }
        for lease in held { lease.release() }
    }

    public var isReleased: Bool { state.withLock { $0.released } }

    /// How many entries the pin holds, for the tests.
    var leaseCount: Int { state.withLock { $0.leases.count } }

    deinit { release() }
}

extension VideoByteCache {
    /// Chunks pinned past the playhead's own: what a resumed clip reads first
    /// (3 MB, several seconds of a feed clip).
    static let pinChunksAhead = 3
    /// One chunk before it: the playhead's byte offset is an estimate.
    static let pinChunksBehind = 1

    /// Pins the ranges of `url` a player resuming at `fraction` of its length
    /// will read: the content information, the head (where a streamable file
    /// keeps its index), the last chunk (where a file that is not keeps it),
    /// and the chunks around the playhead. Only what is on disk is pinned;
    /// what the player fetches later its own loader pins.
    ///
    /// The playhead's offset is estimated as `fraction` of the file's length,
    /// a constant-bitrate guess, hence the margin on both sides. Without a
    /// fraction (no duration known), only the head, the tail and the content
    /// information are held.
    ///
    /// - Returns: nil for a file the cache does not hold (not cacheable).
    public func pinRanges(of url: URL, near fraction: Double?) -> VideoRangePin? {
        guard Self.isCacheable(url) else { return nil }
        let pin = VideoRangePin()
        let opening = opening
        let chunkSize = chunkSize
        // On the cache's queue: after the stores' open (#1018), and off the
        // caller's thread for the content information's read.
        queue.async {
            guard let store = opening.stores?.store(for: url) else { return }
            let mediaKey = CacheKey.media(url)
            var keys = [VideoCacheKeys.info(mediaKey), VideoCacheKeys.chunk(mediaKey, 0)]
            if let data = store.data(for: VideoCacheKeys.info(mediaKey)),
               let info = try? JSONDecoder().decode(VideoContentInfo.self, from: data), info.length > 0 {
                let last = Int((info.length - 1) / chunkSize)
                var chunks: Set<Int> = [last]
                if let fraction, fraction.isFinite {
                    let offset = Int64(Double(info.length) * min(max(fraction, 0), 1))
                    let around = Int(min(offset, info.length - 1) / chunkSize)
                    let first = max(1, around - Self.pinChunksBehind)
                    let end = min(last, around + Self.pinChunksAhead)
                    if first <= end { chunks.formUnion(first...end) }
                }
                chunks.remove(0)
                for chunk in chunks.sorted() {
                    // A cancelled fetch's prefix counts: the resume reads it first.
                    let whole = VideoCacheKeys.chunk(mediaKey, chunk)
                    keys.append(store.contains(whole) ? whole : VideoCacheKeys.partial(mediaKey, chunk))
                }
            }
            pin.adopt(keys.compactMap { store.lease($0) })
            VideoCacheAudit.emit("pin \(url.lastPathComponent) entries=\(pin.leaseCount)")
        }
        return pin
    }
}
