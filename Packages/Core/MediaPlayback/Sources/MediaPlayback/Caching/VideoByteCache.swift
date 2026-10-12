import AVFoundation
import CacheKit
import Foundation
import ObjectiveC
import Synchronization

/// The device cache's video bytes (#895, epic #890): progressive MP4 ranges
/// on disk, served to `AVPlayer` through a resource loader, and the head
/// ranges the vertical feed preloads for the videos after the next.
///
/// ## Storage
///
/// Two `DiskStore` namespaces in the `.video` pool (500 MB in Automatic),
/// class `standard`, shared 3:1 as the images pool is (#894):
///
/// - `video` (`public`): files at a URL that carries no signature. Kept on
///   logout: the same bytes for every viewer.
/// - `video.signed` (`signed`): files behind a presigned URL (`X-Amz-*`, …,
///   `CacheKey.isSigned`). Only this viewer was allowed to fetch them: wiped
///   with the viewer.
///
/// Both are keyed by `CacheKey.media(url)` (the URL minus its signature), cut
/// into 1 MB chunks (`VideoRangeLoader`): chunk 0 is the head range.
///
/// ⚠️ **OPENED OFF THE CALLER'S THREAD** (#1018). Opening a store reads its
/// index and lists its files, and the app creates this cache on main with its
/// first playback pool. The stores open on the cache's own serial queue, the
/// one every resource loader runs on, so a load enqueued after the open waits
/// for it by construction. Until then a synchronous check (`hasHead`) answers
/// "not cached". Both namespaces join the coordinator at once, through
/// `DeferredVideoDisk`, so a logout or a clear during the open is applied when
/// the stores attach.
///
/// ## Playback
///
/// `asset(for:priority:)` gives the player an `AVURLAsset` on a private
/// scheme (`cpvideo+https://…`), so AVFoundation asks the resource loader for
/// every byte: answered from disk where the cache has it, fetched where it
/// has a gap, and written back.
///
/// ⚠️ **Progressive files only.** A resource loader cannot serve the media
/// segments of an HLS stream (AVFoundation refuses them), so an `.m3u8` URL
/// gets a plain asset and stays on the network path. Caching HLS needs a
/// local proxy that rewrites the manifest (what player SDKs ship), the
/// follow-up when the backend serves manifests.
///
/// ## Preload
///
/// `preloadHead(of:priority:owner:)` writes a file's head range to disk as a
/// `speculative` entry through a plain range request, with no player: the
/// +2/+3 pages of the vertical feed (`VideoLookahead`). Fills are coalesced
/// per file and arbitrated by the coordinator's P2 allowance.
public final class VideoByteCache: Sendable {
    /// The chunk size, and the head range a preload fetches: 1 MB, the top of
    /// the 800 KB–1 MB BytePlus / TikTok head chunk (#970).
    public static let chunkSize: Int64 = 1_000_000
    public static let diskVersion = 1
    /// The private scheme prefix: `https` becomes `cpvideo+https`.
    static let schemePrefix = "cpvideo+"

    public static let publicNamespace = CacheNamespace("video", category: .videos, scope: .public, priorityClass: .standard)
    public static let signedNamespace = CacheNamespace("video.signed", category: .videos, scope: .signed, priorityClass: .standard)
    /// Public media 3, signed media 1: the images pool's split (#894).
    static let publicDiskBudget = DiskBudget(pool: .video, weight: 3)
    static let signedDiskBudget = DiskBudget(pool: .video, weight: 1)

    /// The two namespaces as the coordinator sees them, registered before
    /// their stores open.
    private let publicDisk: DeferredVideoDisk
    private let signedDisk: DeferredVideoDisk
    private let opening: VideoStoreOpening
    let statistics = VideoCacheStatistics()
    private let fetcher: any VideoRangeFetching
    private let heads: CacheFills<String, Void>
    private let coordinator: CacheCoordinator?
    private let chunkSize: Int64
    private let cancelGrace: TimeInterval
    /// The resource loaders' delegate queue, shared by every cached asset.
    let queue = DispatchQueue(label: "MediaPlayback.VideoByteCache", qos: .userInitiated)

    /// Opens the video namespaces under the app's `Caches` and registers them
    /// with `coordinator`, which sets their budgets, wipes the signed one on
    /// every viewer change, and arbitrates head preloads. Open ONE per
    /// process (`DiskStore`).
    ///
    /// Returns at once: the stores open on the cache's queue (#1018).
    public convenience init(coordinator: CacheCoordinator) {
        self.init(coordinator: coordinator, root: nil)
    }

    /// - Parameter beforeOpen: runs on the cache's queue just before the
    ///   stores open. Tests hold the open there.
    init(
        coordinator: CacheCoordinator?,
        root: URL?,
        fetcher: any VideoRangeFetching = URLSessionVideoRangeFetcher(),
        clock: any CacheClock = SystemCacheClock(),
        slots: CacheFillSlots? = nil,
        chunkSize: Int64 = VideoByteCache.chunkSize,
        cancelGrace: TimeInterval = VideoRangeLoader.defaultCancelGrace,
        beforeOpen: (@Sendable () -> Void)? = nil
    ) {
        let publicDisk = DeferredVideoDisk(namespace: Self.publicNamespace, budget: Self.publicDiskBudget)
        let signedDisk = DeferredVideoDisk(namespace: Self.signedNamespace, budget: Self.signedDiskBudget)
        let storeOpening = VideoStoreOpening()
        opening = storeOpening
        self.publicDisk = publicDisk
        self.signedDisk = signedDisk
        self.fetcher = fetcher
        self.coordinator = coordinator
        self.chunkSize = chunkSize
        self.cancelGrace = cancelGrace
        heads = CacheFills(slots: slots ?? coordinator?.fillSlots ?? CacheFillSlots())
        // Registered now, before the stores exist: budgets, a logout and a
        // clear reach the namespaces from the first instant.
        coordinator?.register(publicDisk)
        coordinator?.register(signedDisk)
        queue.async {
            beforeOpen?()
            let stores = VideoStores(root: root, clock: clock)
            if let stores {
                publicDisk.attach(stores.common)
                signedDisk.attach(stores.signed)
            }
            storeOpening.finish(stores)
        }
    }

    // MARK: - Policy

    /// Whether `url` goes through the cache: a progressive file over HTTP(S).
    /// HLS manifests and local files never do.
    public static func isCacheable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.pathExtension.lowercased() != "m3u8"
    }

    /// The store `url`'s bytes live in, once the stores are open; `nil` while
    /// they open (or if they could not).
    func store(for url: URL) -> DiskStore? {
        opening.stores?.store(for: url)
    }

    /// Waits until the stores are open (or failed to). Tests and the audit;
    /// a load never needs to, it runs after the open on the same queue.
    public func waitUntilStoresAreOpen() async {
        let queue = queue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Whether the stores were opened on the main thread (never), for tests;
    /// `nil` until they are open.
    var storesOpenedOnMainThread: Bool? { opening.stores?.openedOnMainThread }

    /// The stores, waiting for the open. Tests only: never on `queue`, never
    /// on main in the app.
    private var openedStores: VideoStores {
        queue.sync {}
        guard let stores = opening.stores else { preconditionFailure("the video stores could not open") }
        return stores
    }

    var publicStore: DiskStore { openedStores.common }
    var signedStore: DiskStore { openedStores.signed }

    /// The coordinator's current prefetch policy: `.full` without one.
    public var prefetchPolicy: PrefetchPolicy { coordinator?.prefetchPolicy ?? .full }

    /// Tells the coordinator whether the playing video is under-buffered:
    /// while it is, no P2 fill starts anywhere in the app.
    public func setPlaybackUnderBuffered(_ underBuffered: Bool) {
        coordinator?.setPlaybackUnderBuffered(underBuffered)
    }

    /// What the cache has served, for the audit log and the tests.
    public var statisticsSnapshot: VideoCacheStatistics.Snapshot { statistics.snapshot }

    // MARK: - Playback

    private nonisolated(unsafe) static var delegateKey: UInt8 = 0

    /// The asset a player should open for `url`: on the private scheme with
    /// the cache's resource loader when `url` is cacheable, a plain asset
    /// otherwise.
    public func asset(for url: URL, priority: CacheFillPriority = .visible) -> AVURLAsset {
        guard Self.isCacheable(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme
        else { return AVURLAsset(url: url) }
        components.scheme = Self.schemePrefix + scheme
        guard let privateURL = components.url else { return AVURLAsset(url: url) }
        let asset = AVURLAsset(url: privateURL)
        let loader = makeLoader(for: url, mode: .playback, priority: priority)
        let delegate = VideoAssetLoaderDelegate(loader: loader)
        asset.resourceLoader.setDelegate(delegate, queue: queue)
        objc_setAssociatedObject(asset, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    /// Raises or lowers the network priority of a cached asset's fetches: a
    /// warmed +1 player becomes the playing one.
    public func setPriority(_ priority: CacheFillPriority, of asset: AVAsset) {
        guard let delegate = objc_getAssociatedObject(asset, &Self.delegateKey) as? VideoAssetLoaderDelegate else { return }
        let loader = delegate.loader
        queue.async { loader.setPriority(priority.urlSessionTaskPriority) }
    }

    /// Whether `asset` reads through this cache.
    public func isCached(_ asset: AVAsset) -> Bool {
        objc_getAssociatedObject(asset, &Self.delegateKey) is VideoAssetLoaderDelegate
    }

    func makeLoader(for url: URL, mode: VideoRangeLoader.Mode, priority: CacheFillPriority) -> VideoRangeLoader {
        let counters = coordinator?.prefetchCounters
        let storeOpening = opening
        // Resolved on `queue`, at the loader's first request: by then the
        // open block, enqueued first, has run.
        return VideoRangeLoader(
            remote: url, store: { storeOpening.stores?.store(for: url) }, fetcher: fetcher, queue: queue, mode: mode,
            priority: priority.urlSessionTaskPriority, statistics: statistics, chunkSize: chunkSize,
            cancelGrace: cancelGrace,
            onFirstRange: { hit in counters?.recordNextVideoStart(firstRangeHit: hit) }
        )
    }

    /// A player bound to a surface showed its first frame `seconds` after it
    /// was asked to play: the coordinator's prefetch counters (#900).
    public func recordTimeToFirstFrame(_ seconds: Double) {
        coordinator?.prefetchCounters.recordTimeToFirstFrame(seconds)
    }

    // MARK: - Head preload

    /// Whether `url`'s head range and content information are on disk.
    public func hasHead(of url: URL) -> Bool {
        // Not open yet: not cached, as far as anyone may wait to know.
        guard let namespace = store(for: url) else { return false }
        let key = CacheKey.media(url)
        return namespace.contains(VideoCacheKeys.info(key)) && namespace.contains(VideoCacheKeys.chunk(key, 0))
    }

    /// Writes `url`'s head range (the first chunk) to disk as `speculative`,
    /// with a range request and no player. Shared with any preload of the same
    /// file already in flight; cancelled when no owner wants it any more (the
    /// owner revoked on a swipe). A P2 request waits for a slot of the
    /// coordinator's speculative allowance.
    ///
    /// - Returns: `nil` when there is nothing to do: not cacheable, or the
    ///   head is already on disk.
    @discardableResult
    public func preloadHead(of url: URL, priority: CacheFillPriority = .speculative, owner: CacheOwner) -> CacheFillInterest? {
        guard Self.isCacheable(url), !hasHead(of: url) else { return nil }
        return heads.request(CacheKey.media(url), priority: priority, owner: owner) { [weak self] context in
            guard let self else { return }
            try await fetchHead(of: url, context: context)
        }
    }

    /// Whether a head preload of `url` is queued or running.
    public func isPreloadingHead(of url: URL) -> Bool {
        heads.isInFlight(CacheKey.media(url))
    }

    /// Fetches the head through a speculative loader, as a request for
    /// `[0, chunkSize)` that keeps no bytes in memory.
    private func fetchHead(of url: URL, context: CacheFillContext) async throws {
        guard !hasHead(of: url) else { return }
        let loader = makeLoader(for: url, mode: .speculative, priority: context.priority)
        let queue = queue
        context.onPriorityChange { priority in
            queue.async { loader.setPriority(priority.urlSessionTaskPriority) }
        }
        let request = HeadRequest(length: chunkSize)
        let id = ObjectIdentifier(request)
        VideoCacheAudit.emit("head preload START \(url.absoluteString)")
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    // A cancel that got here first has invalidated the
                    // loader (same queue), which ends this request at once.
                    queue.async {
                        request.continuation = continuation
                        loader.handle(request, id: id)
                    }
                }
            } onCancel: {
                queue.async {
                    loader.cancel(id: id)
                    loader.invalidate()
                    request.finishLoading(with: CancellationError())
                }
            }
        } catch {
            VideoCacheAudit.emit("head preload CANCELLED \(url.absoluteString)")
            throw error
        }
        queue.async { loader.invalidate() }
        statistics.update { $0.headPreloads += 1 }
        VideoCacheAudit.emit("head preload DONE \(url.absoluteString)")
    }

    /// A head preload's request: bytes go to disk through the loader, nothing
    /// is kept here. Touched on the cache's queue only.
    private final class HeadRequest: VideoLoadingRequest, @unchecked Sendable {
        let dataRange: VideoDataRange?
        var continuation: CheckedContinuation<Void, any Error>?

        init(length: Int64) {
            dataRange = VideoDataRange(offset: 0, length: length, toEnd: false)
        }

        var wantsContentInformation: Bool { false }
        func fill(_ info: VideoContentInfo) {}
        func respond(with data: Data) {}

        func finishLoading() {
            continuation?.resume()
            continuation = nil
        }

        func finishLoading(with error: any Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

/// `-cache-audit`: one line per video cache decision (first range hit or
/// miss, fetches, head preloads), in DEBUG builds only.
enum VideoCacheAudit {
    #if DEBUG
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-cache-audit")
    #endif

    static func emit(_ line: @autoclosure () -> String) {
        #if DEBUG
        guard isEnabled else { return }
        let text: String = line()
        print("[cache-audit] video \(text)")
        #endif
    }
}

/// The video cache's two disk stores, opened together.
struct VideoStores: Sendable {
    let common: DiskStore
    let signed: DiskStore
    /// Never `true` in the app: the cache opens them on its queue (#1018).
    let openedOnMainThread: Bool

    init?(root: URL?, clock: any CacheClock) {
        openedOnMainThread = Thread.isMainThread
        // Until the coordinator's limits reach them: the Automatic split.
        let shares = DiskBudget.split(
            DiskPool.video.automaticBytes, among: [VideoByteCache.publicDiskBudget, VideoByteCache.signedDiskBudget]
        )
        do {
            common = try DiskStore(
                namespace: VideoByteCache.publicNamespace, version: VideoByteCache.diskVersion,
                budget: VideoByteCache.publicDiskBudget, root: root,
                limits: CacheLimits(bytes: shares[0], speculativeShare: CacheCoordinator.speculativeShare), clock: clock
            )
            signed = try DiskStore(
                namespace: VideoByteCache.signedNamespace, version: VideoByteCache.diskVersion,
                budget: VideoByteCache.signedDiskBudget, root: root,
                limits: CacheLimits(bytes: shares[1], speculativeShare: CacheCoordinator.speculativeShare), clock: clock
            )
        } catch {
            #if DEBUG
            print("[video] disk cache unavailable, streaming only: \(error)")
            #endif
            return nil
        }
    }

    func store(for url: URL) -> DiskStore {
        CacheKey.isSigned(url) ? signed : common
    }
}

/// Where the open stands: opening, then the stores (or `nil` if they could
/// not open).
final class VideoStoreOpening: Sendable {
    private let state = Mutex<(done: Bool, stores: VideoStores?)>((false, nil))

    var stores: VideoStores? { state.withLock { $0.stores } }
    var isDone: Bool { state.withLock { $0.done } }

    func finish(_ stores: VideoStores?) {
        state.withLock { $0 = (true, stores) }
    }
}
