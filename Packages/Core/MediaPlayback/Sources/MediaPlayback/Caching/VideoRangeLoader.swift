import AVFoundation
import CacheKit
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// What a content-information request is answered with, and what the cache
/// keeps about a file next to its bytes.
struct VideoContentInfo: Codable, Sendable, Equatable {
    let length: Int64
    /// A UTI, as `AVAssetResourceLoadingContentInformationRequest` wants it.
    let contentType: String
}

/// The bytes a loading request asks for.
struct VideoDataRange: Sendable, Equatable {
    let offset: Int64
    let length: Int64
    /// `requestsAllDataToEndOfResource`: `length` is only a hint.
    let toEnd: Bool
}

/// One request from a player (or from a head preload), seen by the loader
/// through what it needs: `AVAssetResourceLoadingRequest` in the app, a fake
/// that records what it received in a test.
protocol VideoLoadingRequest: AnyObject {
    var wantsContentInformation: Bool { get }
    var dataRange: VideoDataRange? { get }
    func fill(_ info: VideoContentInfo)
    func respond(with data: Data)
    func finishLoading()
    func finishLoading(with error: any Error)
}

/// The cache's keys for one media file: its content information, its whole
/// chunks, and the prefix of a chunk a cancelled fetch left behind.
enum VideoCacheKeys {
    static func info(_ media: String) -> String { media + "#info" }
    static func chunk(_ media: String, _ index: Int) -> String { media + "#\(index)" }
    static func partial(_ media: String, _ index: Int) -> String { media + "#\(index)~" }
}

/// Counters for the `-cache-audit` log and the tests.
public final class VideoCacheStatistics: Sendable {
    public struct Snapshot: Sendable, Equatable {
        /// Playbacks whose first range was on disk when the player asked.
        public var firstRangeHits = 0
        /// Playbacks whose first range had to come from the network.
        public var firstRangeMisses = 0
        /// Bytes handed to players and preloads.
        public var servedBytes: Int64 = 0
        /// Bytes received from the network.
        public var networkBytes: Int64 = 0
        /// Head ranges preloaded to disk (P2).
        public var headPreloads = 0
    }

    private let state = Mutex(Snapshot())

    public init() {}

    public var snapshot: Snapshot { state.withLock { $0 } }

    func update(_ change: (inout Snapshot) -> Void) {
        state.withLock { change(&$0) }
    }
}

/// The byte ranges of ONE progressive file, served to a player from the
/// video cache and fetched from the network only where the cache has a gap
/// (#895).
///
/// ## Chunks
///
/// The file is cut into chunks of `chunkSize` (1 MB). Each whole chunk is
/// one `DiskStore` entry, so the store's tiers, leases and LRU order apply
/// per chunk. Chunk 0 is the HEAD range: what a head preload fetches and
/// what the first frame needs.
///
/// - **Tiers.** A head preload writes `speculative` (P2: never shown, evicted
///   first, the only speculative bytes, which bounds flash wear). A player
///   writes its head `retained` and every later chunk `recent`, so a watched
///   TAIL goes before any played HEAD: a replay or a swipe back needs the head
///   first, and rarely the tail.
/// - **Leases.** A player's loader leases every chunk it serves or writes,
///   for as long as the asset lives: the playing video is pinned.
/// - **Partial chunks.** A fetch cancelled mid-chunk keeps what it got under
///   the chunk's partial key, if it is worth a file (64 KB), so the next
///   request resumes from there instead of fetching those bytes again.
///
/// ## Requests
///
/// Content information is answered from the cache, or from the first
/// response. Data is served in order from memory, then disk; a gap starts ONE
/// fetch covering the run of chunks nobody holds or fetches, up to what the
/// request needs. A request cancelled by the player (`didCancel`) cancels the
/// fetches nobody else waits on, after a short grace: a player cancels and
/// re-asks for the next bytes in the same breath, and that one adopts the
/// fetch already running.
///
/// Confined to `queue`: every method runs there (the resource loader's
/// delegate queue), and fetch callbacks hop onto it.
final class VideoRangeLoader: @unchecked Sendable {
    // `@unchecked`: all mutable state is touched on `queue` only.

    enum Mode: Sendable {
        /// A player's asset: heads `retained`, tails `recent`, leased.
        case playback
        /// A P2 head preload: `speculative`, never leased, off Low Data Mode.
        case speculative
    }

    /// The smallest partial chunk worth a file.
    static let minimumPartialBytes = 64 * 1024
    /// How long a fetch nobody waits on survives before it is cancelled.
    static let defaultCancelGrace: TimeInterval = 0.3

    let remote: URL
    let mediaKey: String
    let queue: DispatchQueue
    let mode: Mode
    let chunkSize: Int64
    private let fetcher: any VideoRangeFetching
    private let statistics: VideoCacheStatistics
    private let cancelGrace: TimeInterval
    /// Reports a playback's first range, hit or miss, to the coordinator's
    /// prefetch counters (#900): `nextVideoFirstRange` in `-cache-audit`.
    private let onFirstRange: (@Sendable (Bool) -> Void)?
    private(set) var priority: Float
    private let storeProvider: @Sendable () -> DiskStore?
    /// The store, resolved at the first use on `queue` (#1018): the cache
    /// opens its stores on this queue, ahead of any request. `nil` when they
    /// could not open: the loader then streams, keeping only what it holds in
    /// memory.
    private lazy var store: DiskStore? = storeProvider()

    private final class Pending {
        let id: ObjectIdentifier
        let request: any VideoLoadingRequest
        let range: VideoDataRange?
        var needsInfo: Bool
        var cursor: Int64

        init(id: ObjectIdentifier, request: any VideoLoadingRequest) {
            self.id = id
            self.request = request
            range = request.dataRange
            needsInfo = request.wantsContentInformation
            cursor = request.dataRange?.offset ?? 0
        }

        /// Where the request ends, once the file's length is known.
        func end(total: Int64?) -> Int64? {
            guard let range else { return nil }
            let requested: Int64? = range.toEnd ? nil : range.offset + range.length
            switch (requested, total) {
            case let (requested?, total?): return min(requested, total)
            case let (requested?, nil): return requested
            case let (nil, total?): return total
            case (nil, nil): return nil
            }
        }
    }

    private final class Fetch {
        let id: Int
        let start: Int64
        var position: Int64
        /// Exclusive. Lowered when another fetch takes over the rest.
        var end: Int64
        /// Bytes to drop first: a server that ignored the range sent from 0.
        var skip: Int64 = 0
        var task: (any VideoRangeTask)?

        init(id: Int, start: Int64, end: Int64) {
            self.id = id
            self.start = start
            position = start
            self.end = end
        }
    }

    private var info: VideoContentInfo?
    private var pending: [Pending] = []
    private var fetches: [Fetch] = []
    private var nextFetchID = 0
    /// Prefixes of chunks being filled.
    private var buffers: [Int: Data] = [:]
    /// The last whole chunks read or fetched, newest last: a player reads the
    /// same chunk in several requests.
    private var recentChunks: [(index: Int, data: Data)] = []
    private static let recentChunkCount = 2
    private var leases: [String: CacheLease] = [:]
    private var invalidated = false
    private var reportedFirstRange = false
    private var idleCheckScheduled = false

    init(
        remote: URL, store: @escaping @Sendable () -> DiskStore?, fetcher: any VideoRangeFetching,
        queue: DispatchQueue, mode: Mode,
        priority: Float, statistics: VideoCacheStatistics, chunkSize: Int64 = VideoByteCache.chunkSize,
        cancelGrace: TimeInterval = VideoRangeLoader.defaultCancelGrace,
        onFirstRange: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.remote = remote
        mediaKey = CacheKey.media(remote)
        storeProvider = store
        self.fetcher = fetcher
        self.queue = queue
        self.mode = mode
        self.priority = priority
        self.statistics = statistics
        self.chunkSize = max(1, chunkSize)
        self.cancelGrace = cancelGrace
        self.onFirstRange = onFirstRange
    }

    // MARK: - Requests

    func handle(_ request: any VideoLoadingRequest, id: ObjectIdentifier) {
        guard !invalidated else {
            request.finishLoading(with: CancellationError())
            return
        }
        let entry = Pending(id: id, request: request)
        if mode == .playback, !reportedFirstRange, entry.range?.offset == 0 {
            reportedFirstRange = true
            let hit = store?.contains(VideoCacheKeys.chunk(mediaKey, 0)) ?? false
            statistics.update { hit ? ($0.firstRangeHits += 1) : ($0.firstRangeMisses += 1) }
            onFirstRange?(hit)
            let verdict: String = hit ? "HIT" : "MISS"
            let address: String = remote.absoluteString
            VideoCacheAudit.emit("first-range \(verdict) \(address)")
        }
        pending.append(entry)
        pump()
    }

    func cancel(id: ObjectIdentifier) {
        pending.removeAll { $0.id == id }
        guard cancelGrace > 0 else {
            cancelIdleFetches()
            return
        }
        guard !idleCheckScheduled else { return }
        idleCheckScheduled = true
        queue.asyncAfter(deadline: .now() + cancelGrace) { [weak self] in
            guard let self else { return }
            idleCheckScheduled = false
            cancelIdleFetches()
        }
    }

    func setPriority(_ priority: Float) {
        self.priority = priority
        for fetch in fetches { fetch.task?.setPriority(priority) }
    }

    /// The asset is gone: every fetch stops (keeping its partial chunk), every
    /// request still waiting ends, every lease goes.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        for fetch in fetches {
            fetch.task?.cancel()
        }
        fetches.removeAll()
        for chunk in Array(buffers.keys) { persistPartial(chunk) }
        let waiting = pending
        pending.removeAll()
        for entry in waiting { entry.request.finishLoading(with: CancellationError()) }
        for lease in leases.values { lease.release() }
        leases.removeAll()
        buffers.removeAll()
        recentChunks.removeAll()
    }

    var fetchCount: Int { fetches.count }

    // MARK: - Serving

    private func pump() {
        guard !invalidated else { return }
        loadStoredInfoIfNeeded()
        var index = 0
        while index < pending.count {
            if serve(pending[index]) {
                pending.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    /// Moves `entry` as far as the bytes at hand allow. True once finished.
    private func serve(_ entry: Pending) -> Bool {
        guard let info else {
            requestBytes(at: entry.cursor, until: entry.end(total: nil))
            return false
        }
        if entry.needsInfo {
            entry.request.fill(info)
            entry.needsInfo = false
        }
        guard let end = entry.end(total: info.length) else {
            entry.request.finishLoading()
            return true
        }
        while entry.cursor < end {
            let chunk = Int(entry.cursor / chunkSize)
            let chunkStart = Int64(chunk) * chunkSize
            guard let bytes = available(chunk, total: info.length),
                  entry.cursor < chunkStart + Int64(bytes.count)
            else {
                requestBytes(at: entry.cursor, until: end)
                return false
            }
            let from = Int(entry.cursor - chunkStart)
            let to = Int(min(Int64(bytes.count), end - chunkStart))
            entry.request.respond(with: bytes.subdata(in: bytes.startIndex + from ..< bytes.startIndex + to))
            statistics.update { $0.servedBytes += Int64(to - from) }
            entry.cursor = chunkStart + Int64(to)
        }
        entry.request.finishLoading()
        return true
    }

    /// The bytes of `chunk` at hand: whole from memory or disk, or the prefix
    /// being filled (or left on disk by a cancelled fetch).
    private func available(_ chunk: Int, total: Int64) -> Data? {
        if let recent = recentChunks.last(where: { $0.index == chunk }) { return recent.data }
        if let buffer = buffers[chunk] { return buffer }
        let key = VideoCacheKeys.chunk(mediaKey, chunk)
        if let store, store.contains(key), let data = store.data(for: key) {
            if Int64(data.count) == chunkLength(chunk, total: total) {
                adoptStored(key, isHead: chunk == 0)
                remember(chunk, data)
                return data
            }
            // A file of another length: the resource changed under its URL.
            store.removeValue(for: key)
        }
        let partial = VideoCacheKeys.partial(mediaKey, chunk)
        if let store, store.contains(partial), let data = store.data(for: partial),
           !data.isEmpty, Int64(data.count) < chunkLength(chunk, total: total) {
            buffers[chunk] = data
            return data
        }
        return nil
    }

    /// Whether `chunk` is whole or being filled somewhere, so a new fetch
    /// stops before it.
    private func isHeld(_ chunk: Int) -> Bool {
        recentChunks.contains { $0.index == chunk }
            || buffers[chunk] != nil
            || store?.contains(VideoCacheKeys.chunk(mediaKey, chunk)) == true
            || store?.contains(VideoCacheKeys.partial(mediaKey, chunk)) == true
    }

    private func isClaimed(_ chunk: Int) -> Bool {
        let start = Int64(chunk) * chunkSize
        let end = start + chunkSize
        return fetches.contains { $0.position < end && $0.end > start }
    }

    /// Makes sure the bytes at `offset` are on their way.
    private func requestBytes(at offset: Int64, until end: Int64?) {
        // Already coming, and close enough to wait for.
        let coming = fetches.first { $0.position <= offset && offset < $0.end }
        if let coming, offset - coming.position <= chunkSize { return }
        let chunk = Int(offset / chunkSize)
        let chunkStart = Int64(chunk) * chunkSize
        let prefix = Int64(buffers[chunk]?.count ?? 0)
        let start = chunkStart + prefix
        guard start <= offset else { return }
        // A far-behind fetch stops where this one starts.
        if let coming, coming.end > chunkStart { coming.end = chunkStart }
        guard let total = info?.length else {
            // The first fetch learns the length: one chunk, answered fast.
            if fetches.isEmpty { startFetch(from: start, to: chunkStart + chunkSize) }
            return
        }
        let limit = min(roundedUp(end ?? total), total)
        var stop = chunk + 1
        while Int64(stop) * chunkSize < limit, !isHeld(stop), !isClaimed(stop) {
            stop += 1
        }
        startFetch(from: start, to: min(Int64(stop) * chunkSize, total))
    }

    private func startFetch(from start: Int64, to end: Int64) {
        guard start < end else { return }
        let id = nextFetchID
        nextFetchID += 1
        let fetch = Fetch(id: id, start: start, end: end)
        fetches.append(fetch)
        let queue = queue
        // Weak until an event arrives: a fetch outliving its loader (the asset
        // went) delivers to nobody.
        let events = VideoRangeFetchEvents(
            response: { [weak self] response in
                guard let self else { return }
                queue.async { self.received(response, fetch: id) }
            },
            data: { [weak self] data in
                guard let self else { return }
                queue.async { self.received(data, fetch: id) }
            },
            finish: { [weak self] failure in
                guard let self else { return }
                queue.async { self.finished(fetch: id, failure: failure) }
            }
        )
        let kind: String = mode == .speculative ? " (head preload)" : ""
        let last: Int64 = end - 1
        VideoCacheAudit.emit("fetch \(remote.lastPathComponent) bytes=\(start)-\(last)\(kind)")
        fetch.task = fetcher.fetch(
            remote, from: start, to: end, speculative: mode == .speculative, priority: priority, events: events
        )
    }

    // MARK: - Fetch events

    private func activeFetch(_ id: Int) -> Fetch? { fetches.first { $0.id == id } }

    private func received(_ response: VideoRangeResponse, fetch id: Int) {
        guard !invalidated, let fetch = activeFetch(id) else { return }
        if response.offset != fetch.start {
            guard response.offset == 0 else {
                fail(fetch, VideoRangeFetchFailure(VideoRangeFetchError.truncated))
                return
            }
            fetch.skip = fetch.start
        }
        if info == nil {
            guard let total = response.totalLength else {
                fail(fetch, VideoRangeFetchFailure(VideoRangeFetchError.unknownLength))
                return
            }
            let made = VideoContentInfo(length: total, contentType: Self.contentType(mime: response.mimeType, url: remote))
            info = made
            storeInfo(made)
        } else if let total = response.totalLength, total != info?.length {
            // The file changed under its URL: what the cache says about it is
            // stale (its chunks are size-checked on read), and the next
            // player learns it again.
            store?.removeValue(for: VideoCacheKeys.info(mediaKey))
            fail(fetch, VideoRangeFetchFailure(VideoRangeFetchError.truncated))
            return
        }
        if let total = info?.length { fetch.end = min(fetch.end, total) }
        pump()
    }

    private func received(_ data: Data, fetch id: Int) {
        guard !invalidated, let fetch = activeFetch(id), let info else { return }
        statistics.update { $0.networkBytes += Int64(data.count) }
        var offset = 0
        if fetch.skip > 0 {
            let skipped = Int(min(fetch.skip, Int64(data.count)))
            offset += skipped
            fetch.skip -= Int64(skipped)
        }
        while offset < data.count, fetch.position < fetch.end {
            let chunk = Int(fetch.position / chunkSize)
            let chunkStart = Int64(chunk) * chunkSize
            let chunkEnd = chunkStart + chunkLength(chunk, total: info.length)
            let take = Int(min(Int64(data.count - offset), chunkEnd - fetch.position, fetch.end - fetch.position))
            let buffer = buffers[chunk] ?? Data()
            let whole = recentChunks.contains { $0.index == chunk }
            if whole || Int64(buffer.count) != fetch.position - chunkStart {
                // Whole already, or filled past (or short of) this position
                // by another source: these bytes cannot extend it.
                offset += take
                fetch.position += Int64(take)
                continue
            }
            var grown = buffer
            grown.append(data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + take))
            offset += take
            fetch.position += Int64(take)
            if Int64(grown.count) == chunkEnd - chunkStart {
                buffers[chunk] = nil
                commit(chunk, grown)
            } else {
                buffers[chunk] = grown
            }
        }
        if fetch.position >= fetch.end {
            // Its claim is served; a server sending past it is stopped.
            fetch.task?.cancel()
            fetches.removeAll { $0 === fetch }
        }
        pump()
    }

    private func finished(fetch id: Int, failure: VideoRangeFetchFailure?) {
        guard !invalidated, let fetch = activeFetch(id) else { return }
        fetches.removeAll { $0 === fetch }
        persistPartial(Int(fetch.position / chunkSize))
        if failure != nil || fetch.position < fetch.end {
            fail(fetch, failure ?? VideoRangeFetchFailure(VideoRangeFetchError.truncated))
            return
        }
        pump()
    }

    /// Ends the requests that were waiting on `fetch`.
    private func fail(_ fetch: Fetch, _ failure: VideoRangeFetchFailure) {
        fetch.task?.cancel()
        fetches.removeAll { $0 === fetch }
        VideoCacheAudit.emit("fetch FAILED \(remote.lastPathComponent): \(failure.reason)")
        let doomed = pending.filter { entry in
            guard info != nil else { return true }
            return entry.cursor >= fetch.position && entry.cursor < fetch.end
        }
        pending.removeAll { entry in doomed.contains { $0 === entry } }
        for entry in doomed { entry.request.finishLoading(with: failure) }
        pump()
    }

    /// Cancels every fetch no waiting request needs any more.
    private func cancelIdleFetches() {
        guard !invalidated else { return }
        let idle = fetches.filter { fetch in !pending.contains { waits($0, on: fetch) } }
        for fetch in idle {
            fetch.task?.cancel()
            fetches.removeAll { $0 === fetch }
            persistPartial(Int(fetch.position / chunkSize))
            VideoCacheAudit.emit("fetch cancelled \(remote.lastPathComponent) at=\(fetch.position)")
        }
    }

    private func waits(_ entry: Pending, on fetch: Fetch) -> Bool {
        guard let info else { return true }
        let end = entry.end(total: info.length) ?? entry.cursor
        return entry.cursor < fetch.end && end > fetch.position
    }

    // MARK: - Storage

    private func tier(forChunk chunk: Int) -> CacheTier {
        switch mode {
        case .speculative: .speculative
        case .playback: chunk == 0 ? .retained : .recent
        }
    }

    private func commit(_ chunk: Int, _ data: Data) {
        remember(chunk, data)
        let key = VideoCacheKeys.chunk(mediaKey, chunk)
        let written = (try? store?.write(data, for: key, tier: tier(forChunk: chunk))) ?? false
        if written { leaseIfPlaying(key) }
        let partial = VideoCacheKeys.partial(mediaKey, chunk)
        if store?.contains(partial) == true { store?.removeValue(for: partial) }
    }

    private func persistPartial(_ chunk: Int) {
        guard let info, let buffer = buffers[chunk], buffer.count >= Self.minimumPartialBytes,
              Int64(buffer.count) < chunkLength(chunk, total: info.length)
        else { return }
        let key = VideoCacheKeys.partial(mediaKey, chunk)
        _ = try? store?.write(buffer, for: key, tier: tier(forChunk: chunk))
    }

    private func storeInfo(_ info: VideoContentInfo) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        let key = VideoCacheKeys.info(mediaKey)
        let written = (try? store?.write(data, for: key, tier: tier(forChunk: 0))) ?? false
        if written { leaseIfPlaying(key) }
    }

    private func loadStoredInfoIfNeeded() {
        guard info == nil else { return }
        let key = VideoCacheKeys.info(mediaKey)
        guard let store, store.contains(key), let data = store.data(for: key),
              let stored = try? JSONDecoder().decode(VideoContentInfo.self, from: data)
        else { return }
        info = stored
        adoptStored(key, isHead: true)
    }

    /// A player reading a stored entry pins it, and a head it plays ranks as
    /// a played head from now on, whoever wrote it.
    private func adoptStored(_ key: String, isHead: Bool) {
        guard mode == .playback, let store else { return }
        if isHead, store.tier(of: key) != .retained { store.setTier(.retained, for: key) }
        if leases[key] == nil || leases[key]?.isReleased == true { leaseIfPlaying(key) }
    }

    private func leaseIfPlaying(_ key: String) {
        guard mode == .playback else { return }
        leases[key]?.release()
        leases[key] = store?.lease(key)
    }

    private func remember(_ chunk: Int, _ data: Data) {
        recentChunks.removeAll { $0.index == chunk }
        recentChunks.append((chunk, data))
        if recentChunks.count > Self.recentChunkCount { recentChunks.removeFirst() }
    }

    private func chunkLength(_ chunk: Int, total: Int64) -> Int64 {
        max(0, min(chunkSize, total - Int64(chunk) * chunkSize))
    }

    private func roundedUp(_ offset: Int64) -> Int64 {
        guard offset > 0 else { return 0 }
        let (quotient, remainder) = offset.quotientAndRemainder(dividingBy: chunkSize)
        return (remainder == 0 ? quotient : quotient + 1) * chunkSize
    }

    /// The UTI for a response: its MIME type when that names audiovisual
    /// content, then the URL's extension, then MPEG-4 (what the app plays).
    static func contentType(mime: String?, url: URL) -> String {
        if let mime, let type = UTType(mimeType: mime), type.conforms(to: .audiovisualContent) {
            return type.identifier
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audiovisualContent) {
            return type.identifier
        }
        return UTType.mpeg4Movie.identifier
    }
}

// MARK: - AVFoundation

/// `AVAssetResourceLoadingRequest` as the loader sees it.
private final class LoadingRequestAdapter: VideoLoadingRequest {
    private let request: AVAssetResourceLoadingRequest

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }

    var wantsContentInformation: Bool { request.contentInformationRequest != nil }

    var dataRange: VideoDataRange? {
        request.dataRequest.map {
            VideoDataRange(offset: $0.requestedOffset, length: Int64($0.requestedLength), toEnd: $0.requestsAllDataToEndOfResource)
        }
    }

    func fill(_ info: VideoContentInfo) {
        guard let content = request.contentInformationRequest else { return }
        content.contentType = info.contentType
        content.contentLength = info.length
        content.isByteRangeAccessSupported = true
    }

    func respond(with data: Data) {
        request.dataRequest?.respond(with: data)
    }

    func finishLoading() {
        request.finishLoading()
    }

    func finishLoading(with error: any Error) {
        request.finishLoading(with: error)
    }
}

/// The resource loader delegate of one cached asset. The asset keeps it
/// alive (an associated object: `AVAssetResourceLoader` holds its delegate
/// weakly), and its end ends the loader's fetches and leases.
final class VideoAssetLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    // `@unchecked`: every callback arrives on `loader.queue`, the delegate
    // queue the asset was given.
    let loader: VideoRangeLoader

    init(loader: VideoRangeLoader) {
        self.loader = loader
    }

    deinit {
        let loader = loader
        loader.queue.async { loader.invalidate() }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        loader.handle(LoadingRequestAdapter(loadingRequest), id: ObjectIdentifier(loadingRequest))
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        loader.cancel(id: ObjectIdentifier(loadingRequest))
    }
}
