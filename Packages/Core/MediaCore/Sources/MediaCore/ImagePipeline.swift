import CacheKit
import Foundation
import ImageIO
import Synchronization
import UIKit

/// The pixel size an image is decoded at (#894). A 40 pt avatar decoded at
/// 1200 px costs as much memory as a full-screen photo; a bucket keeps it at
/// what it is shown at. One encoded copy on disk serves every bucket.
///
/// A small bucket covers a square of its size (aspect fill): the SHORT side
/// reaches the bucket, so a cropped avatar or thumbnail is never blurry.
/// `full` keeps the pipeline's long-side maximum, what every caller that names
/// no size has always had.
public enum ImageBucket: Int, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    case px64
    case px128
    case px256
    case px512
    case full

    /// Avatars and small thumbnails: 128 px covers a 40 pt avatar at 3x.
    public static let avatar = ImageBucket.px128

    /// The bucket's pixel size; `nil` for `full` (the pipeline's maximum).
    public var pixels: Int? {
        switch self {
        case .px64: 64
        case .px128: 128
        case .px256: 256
        case .px512: 512
        case .full: nil
        }
    }

    /// The smallest bucket that covers `pixels`, `full` beyond 512.
    public init(fittingPixels pixels: CGFloat) {
        self = Self.allCases.first { ($0.pixels.map(CGFloat.init) ?? .infinity) >= pixels } ?? .full
    }

    /// The smallest bucket that covers a view of `size` points at `scale`.
    public init(fitting size: CGSize, scale: CGFloat) {
        self.init(fittingPixels: max(size.width, size.height) * max(scale, 1))
    }

    /// Avatars and small thumbnails: their own namespaces with a floor (the
    /// Fresco SMALL pattern), so feed media never pushes them out.
    public var isSmall: Bool { self <= .px128 }

    public var description: String { pixels.map { "\($0)px" } ?? "full" }

    public static func < (lhs: ImageBucket, rhs: ImageBucket) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One image at one size: what a list's lookahead asks for (#970).
public struct ImageRequest: Hashable, Sendable {
    public let url: URL
    public let size: ImageBucket

    public init(url: URL, size: ImageBucket = .full) {
        self.url = url
        self.size = size
    }
}

/// What a prefetch does with an image (#970, Texture's two windows).
public enum ImagePrefetchWindow: Sendable, Hashable {
    /// The display window (P1): fetched AND decoded at its bucket, so the cell
    /// that shows it finds it in memory.
    case display
    /// The preload window (P2): bytes to disk only, no decode. Waits for a
    /// slot of the coordinator's global speculative allowance.
    case preload
}

/// Where the pipeline keeps encoded bytes.
public enum ImageDiskLocation: Sendable {
    /// The app's `Caches` folder.
    case caches
    /// A folder of the caller's (tests).
    case folder(URL)
}

/// The app-wide image pipeline (#894, on CacheKit #891):
///
/// memory (decoded, per size bucket) → coalesced fill → disk (encoded bytes)
/// → network → downsampled decode, all off the main thread.
///
/// - **Memory:** decoded bitmaps in byte-budgeted `MemoryCache`s keyed by
///   media key + bucket (`MemoryBudget.decodedImages`: 5% of RAM, 64–256 MB),
///   with a separate `preferred` namespace for avatars and small thumbnails.
///   A lookup is served by the asked bucket or any LARGER one already decoded.
/// - **Disk:** encoded bytes in `DiskStore`s of the `.images` pool: public
///   media, a 30 MB floor for avatars and small thumbnails, and signed media
///   in its own `.signed` namespace, which a logout or a profile switch wipes
///   (public media stay, decision 4 of #890). The stores are opened (folders
///   created, index read and reconciled with the files) on a utility task,
///   never on the caller's thread: fills wait for it, and the synchronous
///   checks read "not on disk" until it is done.
/// - **Keys:** `CacheKey.media(url)`, the URL without its signing query items,
///   so a presigned URL that changes per request is still one entry.
/// - **Fills:** `CacheFills` coalesce every request for a key (visible loads,
///   display-window decodes, preload-window downloads) into ONE fill that runs
///   at the highest priority still wanted and is cancelled only when nobody
///   wants it any more.
/// - **Failures:** a placeholder a fetcher falls back to is never stored under
///   the real key; it and definite failures (a bad response, undecodable
///   bytes) are remembered for `negativeLifetime`, then asked again.
///   Connectivity errors are not remembered: the next request retries.
///
/// Decoding uses `CGImageSourceCreateThumbnailAtIndex`, so a 12MP original
/// costs a bucket-sized bitmap, not a 40MB decode.
///
/// ⚠️ A lock, NOT an `actor`, and the synchronous API is the reason. Every
/// cover gate in the app reads `cachedImage(for:)` synchronously while it
/// configures a cell, and the grids call `prefetch(_:)` straight from layout.
/// While this was an actor those calls compiled with only a WARNING
/// (`#ActorIsolatedCall` — in a UIKit subclass, whose main-actor isolation is
/// inferred, not declared) and ran on the main thread WITHOUT entering the
/// actor, while the actor's own prefetch tasks removed their entries from the
/// same dictionary on the cooperative pool. That data race crashed the app
/// inside `Dictionary._Variant.lookup` (`doesNotRecognizeSelector` on a freed
/// key) under For You's autoplay-cover preloading; see
/// `ImagePipelineConcurrencyTests`. Here every member is genuinely
/// nonisolated, the caches and fills are CacheKit's `Mutex`-guarded types, and
/// the pipeline's own bookkeeping goes through one `Mutex`, so a caller in any
/// isolation is correct and the compiler checks it. Nothing slow runs under a
/// lock: fetching, disk reads and decoding happen in fill tasks.
public final class ImagePipeline: Sendable {
    public static let defaultMaxPixelSize = 1200

    /// How long a placeholder or a definite failure stands for the real image
    /// before the next request asks again.
    public static let defaultNegativeLifetime: TimeInterval = 10

    /// The namespaces the pipeline registers with the `CacheCoordinator`.
    public enum Namespaces {
        public static let decoded = CacheNamespace("images.decoded", category: .images, scope: .public, priorityClass: .standard)
        public static let decodedSmall = CacheNamespace("images.decoded.small", category: .images, scope: .public, priorityClass: .preferred)
        public static let disk = CacheNamespace("images", category: .images, scope: .public, priorityClass: .standard)
        public static let diskSmall = CacheNamespace("images.small", category: .images, scope: .public, priorityClass: .preferred)
        public static let diskSigned = CacheNamespace("images.signed", category: .images, scope: .signed, priorityClass: .standard)
    }

    /// Decoded avatars and small thumbnails: 1% of RAM, 16–48 MB (a 128 px
    /// avatar is 64 KB, so several hundred faces).
    public static let smallDecodedBudget = MemoryBudget.physicalMemoryFraction(
        0.01, minimum: 16 * CacheBytes.mebibyte, maximum: 48 * CacheBytes.mebibyte
    )

    /// The disk floor of avatars and small thumbnails, reserved in the images
    /// pool before feed media.
    public static let smallDiskFloor = 30 * CacheBytes.megabyte

    /// Shares of the images pool after the small floor: public media 3,
    /// signed media 1.
    static let publicDiskWeight = 3
    static let signedDiskWeight = 1

    private struct State {
        var negative: [String: Negative] = [:]
        /// Decoded entries of signed media, dropped when the viewer changes.
        var signedKeys: Set<ImageKey> = []
        /// Bumped by every wipe of signed media, so a fill that started before
        /// it never stores what it fetched for the previous viewer.
        var signedGeneration = 0
        /// `prefetch(_:)`'s interests, by URL.
        var legacyPrefetches: [URL: CacheFillInterest] = [:]
    }

    private enum Negative {
        case failed(until: Date, error: any Error)
        case placeholder(until: Date, data: Data)

        var until: Date {
            switch self {
            case .failed(let until, _), .placeholder(let until, _): until
            }
        }
    }

    private let fetcher: any ImageFetching
    private let maxPixelSize: Int
    private let memory: MemoryCache<ImageKey, UIImage>
    private let smallMemory: MemoryCache<ImageKey, UIImage>
    private let diskPhase = Mutex<DiskPhase>(.off)
    /// The signed namespace, registered at once (before its store opens) so a
    /// logout during the open is never missed.
    private let signedDisk: SignedImageDisk?
    private let decodes: CacheFills<ImageKey, UIImage>
    private let bytes: CacheFills<String, ImageFetchResult>
    private let legacyOwner = CacheOwner("ImagePipeline.prefetch")
    /// Where the pipeline reports its network bytes and, in DEBUG, what each
    /// image found on arrival (`-cache-audit`, #900).
    private let coordinator: CacheCoordinator?
    #if DEBUG
    private let arrivals = ImageArrivals()
    #endif
    private let clock: any CacheClock
    private let negativeLifetime: TimeInterval
    private let state = Mutex(State())

    /// - Parameters:
    ///   - memoryLimit: a fixed byte limit for each memory namespace, for a
    ///     pipeline no coordinator manages; `nil` follows the device
    ///     (`MemoryBudget.decodedImages`). A coordinator's limits win.
    ///   - disk: where encoded bytes go; `nil` keeps the pipeline in memory
    ///     only (tests, the measuring pipeline of a layout).
    ///   - coordinator: registers every namespace with it (budgets, trims,
    ///     logout) and shares its global speculative fill allowance.
    public init(
        fetcher: any ImageFetching,
        maxPixelSize: Int = ImagePipeline.defaultMaxPixelSize,
        memoryLimit: Int? = nil,
        disk: ImageDiskLocation? = nil,
        coordinator: CacheCoordinator? = nil,
        clock: any CacheClock = SystemCacheClock(),
        negativeLifetime: TimeInterval = ImagePipeline.defaultNegativeLifetime
    ) {
        self.fetcher = fetcher
        self.maxPixelSize = maxPixelSize
        self.coordinator = coordinator
        self.clock = clock
        self.negativeLifetime = negativeLifetime
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        func limits(_ budget: MemoryBudget) -> CacheLimits {
            CacheLimits(
                bytes: memoryLimit ?? budget.bytes(physicalMemory: physicalMemory),
                speculativeShare: CacheCoordinator.speculativeShare
            )
        }
        memory = MemoryCache(
            namespace: Namespaces.decoded, budget: .decodedImages,
            limits: limits(.decodedImages), clock: clock
        )
        smallMemory = MemoryCache(
            namespace: Namespaces.decodedSmall, budget: Self.smallDecodedBudget,
            limits: limits(Self.smallDecodedBudget), clock: clock
        )
        let slots = coordinator?.fillSlots ?? CacheFillSlots()
        decodes = CacheFills(slots: slots)
        bytes = CacheFills(slots: slots)
        signedDisk = disk == nil ? nil : SignedImageDisk()

        signedDisk?.setOnRemoveAll { [weak self] in self?.signedMediaWiped() }
        if let coordinator {
            coordinator.register(memory)
            coordinator.register(smallMemory)
            if let signedDisk { coordinator.register(signedDisk) }
        }
        if let disk {
            // Opening reads the index and lists the files: off the caller's
            // thread, which is main for the app's composition root.
            let opening = Task.detached(priority: .utility) { [weak self] () -> ImageDisks? in
                let disks = ImageDisks(location: disk, clock: clock)
                self?.disksOpened(disks, coordinator: coordinator)
                return disks
            }
            diskPhase.withLock { phase in
                if case .off = phase { phase = .opening(opening) }
            }
        }
    }

    private enum DiskPhase {
        case off
        case opening(Task<ImageDisks?, Never>)
        case ready(ImageDisks?)
    }

    /// The opened stores join the coordinator, and the signed one learns to
    /// drop the decoded copies of signed media when it is wiped.
    private func disksOpened(_ disks: ImageDisks?, coordinator: CacheCoordinator?) {
        if let disks {
            signedDisk?.attach(disks.signed)
            if let coordinator {
                coordinator.register(disks.common)
                coordinator.register(disks.small)
            }
        }
        diskPhase.withLock { $0 = .ready(disks) }
    }

    /// The disk stores once open, `nil` while they open (or without a disk).
    private var openDisks: ImageDisks? {
        diskPhase.withLock { phase in
            if case .ready(let disks) = phase { return disks }
            return nil
        }
    }

    /// The disk stores, waiting for them to open. For fills, never the main
    /// thread's synchronous paths.
    private func openingDisks() async -> ImageDisks? {
        let phase = diskPhase.withLock { $0 }
        switch phase {
        case .off: return nil
        case .ready(let disks): return disks
        case .opening(let opening): return await opening.value
        }
    }

    /// Waits until the disk stores are open and registered. Tests and the
    /// audit; the app never needs to.
    public func waitUntilDiskIsOpen() async {
        _ = await openingDisks()
    }

    /// Whether the disk stores were opened on the main thread (never), for tests.
    var diskOpenedOnMainThread: Bool? { openDisks?.openedOnMainThread }

    // MARK: - Loading

    /// Cached-or-loaded image for `url`, decoded at `size`. Concurrent callers
    /// for the same image share one fill (and every bucket of the same media
    /// shares one download).
    ///
    /// Cancelling the calling task drops its interest; the fill is cancelled
    /// only when nobody else (another caller, a prefetch) still wants it.
    public func image(for url: URL, size: ImageBucket = .full, priority: CacheFillPriority = .visible) async throws -> UIImage {
        let key = ImageKey(url: url, bucket: size)
        if let cached = cachedImage(key) {
            if priority == .visible { recordArrival(key, .ready) }
            return cached
        }
        #if DEBUG
        if priority == .visible {
            // A prefetch on its way (a display decode, or a preload's
            // download) saved part of the wait; bytes on disk, all of the
            // network.
            if decodes.isInFlight(key) || bytes.isInFlight(key.media) {
                recordArrival(key, .inFlight)
            } else {
                recordArrival(key, isOnDisk(key) ? .ready : .missed)
            }
        }
        #endif
        return try await decodes.value(for: key, priority: priority) { [self] context in
            try await decodeFill(url, key: key, context: context)
        }
    }

    /// Synchronously returns the cached image if present — for cell
    /// configuration paths that must not suspend. Served by `size` or any
    /// larger bucket already decoded; never touches the disk.
    public func cachedImage(for url: URL, size: ImageBucket = .full) -> UIImage? {
        let key = ImageKey(url: url, bucket: size)
        let image = cachedImage(key)
        // A hit is an arrival found ready; a miss is not one yet: the caller
        // goes on to `image(for:)`, which counts what it finds.
        if image != nil { recordArrival(key, .ready) }
        return image
    }

    /// Seeds the cache with an already-decoded image under `url`. Used for
    /// optimistic rendering: a just-picked local image renders instantly
    /// under its freshly-minted CDN URL, before any network fetch.
    public func store(_ image: UIImage, for url: URL, size: ImageBucket = .full) {
        let key = ImageKey(url: url, bucket: size)
        if key.isSigned { state.withLock { _ = $0.signedKeys.insert(key) } }
        cache(for: size).insert(image, for: key, cost: Self.cost(of: image))
    }

    // MARK: - Prefetching

    /// Registers `owner`'s prefetch of one image (#970). `.display` fetches
    /// and decodes it at `size` (P1); `.preload` writes its bytes to disk
    /// without decoding (P2, waits for a speculative slot). Coalesced with
    /// every other request for the same image.
    ///
    /// - Returns: the interest to raise, lower or release; `nil` when the
    ///   image is already where the window wants it (decoded in memory, or on
    ///   disk for a preload). A revoked owner gets an inactive interest.
    @discardableResult
    public func prefetch(_ url: URL, size: ImageBucket = .full, window: ImagePrefetchWindow, owner: CacheOwner) -> CacheFillInterest? {
        let key = ImageKey(url: url, bucket: size)
        if isDecoded(key) { return nil }
        switch window {
        case .display:
            return decodes.request(key, priority: .next, owner: owner) { [self] context in
                try await decodeFill(url, key: key, context: context)
            }
        case .preload:
            if isOnDisk(key) { return nil }
            return bytes.request(key.media, priority: .speculative, owner: owner) { [self] context in
                try await byteFill(url, key: key, context: context)
            }
        }
    }

    /// Decodes `urls` at full size ahead of display. The grids' existing
    /// prefetch, kept for the lists #970 has not moved to `ImageLookahead`
    /// yet, with its old behaviour: it runs at the visible priority and its
    /// images are stored as seen (`recent`), since the grids prefetch what
    /// they are about to show (For You's autoplay covers) and a speculative
    /// entry could be pushed out by the 20% cap before the cell reads it.
    public func prefetch(_ urls: [URL]) {
        for url in urls {
            let pending = state.withLock { $0.legacyPrefetches[url] }
            if let pending, pending.isActive { continue }
            let key = ImageKey(url: url, bucket: .full)
            if isDecoded(key) { continue }
            let interest = decodes.request(key, priority: .visible, owner: legacyOwner) { [self] context in
                try await decodeFill(url, key: key, context: context)
            }
            state.withLock { state in
                // Finished ones are swept now and then: the grids ask for
                // thousands of covers over a session.
                if state.legacyPrefetches.count >= 256 {
                    state.legacyPrefetches = state.legacyPrefetches.filter { $0.value.isActive }
                }
                state.legacyPrefetches[url] = interest
            }
        }
    }

    /// Drops `prefetch(_:)`'s interest in `urls`: the shared fill is cancelled
    /// if nobody else waits for it.
    public func cancelPrefetch(_ urls: [URL]) {
        let dropped = state.withLock { state in urls.compactMap { state.legacyPrefetches.removeValue(forKey: $0) } }
        for interest in dropped { interest.release() }
    }

    /// Prefetches asked for and not yet finished or cancelled.
    var pendingPrefetchCount: Int {
        state.withLock { state in
            state.legacyPrefetches = state.legacyPrefetches.filter { $0.value.isActive }
            return state.legacyPrefetches.count
        }
    }

    // MARK: - Lookahead signals (#970)

    /// The coordinator's prefetch policy (Low Data, Low Power, thermal state,
    /// network), `.full` for a pipeline no coordinator manages. A list's
    /// lookahead sizes its windows from it.
    public var prefetchPolicy: PrefetchPolicy { coordinator?.prefetchPolicy ?? .full }

    /// Calls `handler` after every change of the coordinator's conditions, on
    /// the thread that made it, so a lookahead re-plans its windows. `nil`
    /// without a coordinator. Keep the token: the observation ends with it.
    public func observePrefetchPolicy(_ handler: @escaping @Sendable (PrefetchPolicy) -> Void) -> CacheObservation? {
        coordinator?.observeConditions { _, policy in handler(policy) }
    }

    /// Calls `handler` after the coordinator trims for a memory warning or
    /// critical memory pressure, on the thread that trimmed: a hidden list's
    /// lookahead drops to nothing (Texture's rule). `nil` without a
    /// coordinator. Keep the token: the observation ends with it.
    public func observeMemoryPressure(_ handler: @escaping @Sendable () -> Void) -> CacheObservation? {
        coordinator?.observeTrims { reason in
            switch reason {
            case .memoryWarning, .memoryCritical: handler()
            default: break
            }
        }
    }

    // MARK: - Introspection

    /// Whether `url` is decoded at `size` or larger, without counting a use.
    public func isDecoded(_ url: URL, size: ImageBucket = .full) -> Bool {
        isDecoded(ImageKey(url: url, bucket: size))
    }

    /// Whether `url`'s encoded bytes are on disk.
    public func isOnDisk(_ url: URL) -> Bool {
        isOnDisk(ImageKey(url: url, bucket: .full))
    }

    /// What both decoded namespaces hold, for tests and the audit.
    var decodedUsage: CacheUsage {
        let large = memory.usage
        let small = smallMemory.usage
        return CacheUsage(bytes: large.bytes + small.bytes, count: large.count + small.count)
    }

    /// How many decodes (and prefetches) wait on `url`'s download, for tests.
    func downloadInterestCount(for url: URL) -> Int {
        bytes.interestCount(for: ImageKey(url: url, bucket: .full).media)
    }

    /// The priority `url`'s download runs at, `nil` when none is in flight:
    /// the highest any of its owners wants, for tests.
    func downloadPriority(for url: URL) -> CacheFillPriority? {
        bytes.priority(of: ImageKey(url: url, bucket: .full).media)
    }

    /// Fills in flight (decodes and downloads), for tests and the audit.
    var inFlightCount: Int { decodes.inFlightCount + bytes.inFlightCount }

    // MARK: - Internals

    private func cache(for bucket: ImageBucket) -> MemoryCache<ImageKey, UIImage> {
        bucket.isSmall ? smallMemory : memory
    }

    private func cachedImage(_ key: ImageKey) -> UIImage? {
        if let exact = cache(for: key.bucket).value(for: key) { return exact }
        for bucket in ImageBucket.allCases where bucket > key.bucket {
            let larger = ImageKey(media: key.media, bucket: bucket, isSigned: key.isSigned)
            let namespace = cache(for: bucket)
            if namespace.contains(larger), let image = namespace.value(for: larger) { return image }
        }
        return nil
    }

    private func isDecoded(_ key: ImageKey) -> Bool {
        ImageBucket.allCases.contains { bucket in
            bucket >= key.bucket && cache(for: bucket).contains(ImageKey(media: key.media, bucket: bucket, isSigned: key.isSigned))
        }
    }

    private func isOnDisk(_ key: ImageKey) -> Bool {
        // Never waits: until the stores are open, nothing reads as on disk.
        guard let disks = openDisks else { return false }
        if key.isSigned { return disks.signed.contains(key.media) }
        return disks.common.contains(key.media) || disks.small.contains(key.media)
    }

    /// The body of the one shared decode per (media, bucket).
    private func decodeFill(_ url: URL, key: ImageKey, context: CacheFillContext) async throws -> UIImage {
        let stores = await openingDisks()
        let generation = state.withLock { $0.signedGeneration }
        var fromDisk = false
        let result: ImageFetchResult
        if let data = diskData(for: key, in: stores) {
            fromDisk = true
            result = ImageFetchResult(data: data, isCacheable: true)
            audit("disk", key)
        } else {
            result = try await download(url, key: key, context: context)
        }
        try Task.checkCancellation()
        let image: UIImage
        do {
            image = try Self.decode(result.data, bucket: key.bucket, maxPixelSize: maxPixelSize)
        } catch {
            if fromDisk { removeFromDisk(key, in: stores) }
            remember(.failed(until: clock.now.addingTimeInterval(negativeLifetime), error: error), for: key.media)
            throw error
        }
        guard result.isCacheable else { return image }
        // A visible load is a use; a display-window decode is speculative
        // until the cell that shows it reads it (`value(for:)` promotes it).
        let tier: CacheTier = context.priority == .visible ? .recent : .speculative
        let decoded = cache(for: key.bucket)
        decoded.insert(image, for: key, cost: Self.cost(of: image), tier: tier)
        if key.isSigned {
            let stale = state.withLock { state -> Bool in
                guard state.signedGeneration == generation else { return true }
                state.signedKeys.insert(key)
                return false
            }
            if stale { decoded.removeValue(for: key) }
        }
        return image
    }

    /// The bytes for `key` through the shared download of its media: every
    /// bucket of one media waits for the same fetch.
    ///
    /// Joined at the decode's priority when it starts, and never below P1: a
    /// P2 decode (a hidden list's) already holds a speculative slot, and two
    /// of them each waiting for a download slot would hold the allowance
    /// forever. A decode raised later (a prefetched cell scrolled on screen)
    /// does not raise a download already running; only its network priority
    /// hint differs.
    private func download(_ url: URL, key: ImageKey, context: CacheFillContext) async throws -> ImageFetchResult {
        try await bytes.value(for: key.media, priority: max(context.priority, .next)) { [self] byteContext in
            try await byteFill(url, key: key, context: byteContext)
        }
    }

    /// The body of the one shared download per media: disk first (a preload
    /// may have landed), then a remembered failure, then the fetcher.
    private func byteFill(_ url: URL, key: ImageKey, context: CacheFillContext) async throws -> ImageFetchResult {
        let stores = await openingDisks()
        if let data = diskData(for: key, in: stores) {
            return ImageFetchResult(data: data, isCacheable: true)
        }
        switch rememberedOutcome(for: key.media) {
        case .failed(_, let error)?:
            throw error
        case .placeholder(_, let data)?:
            return ImageFetchResult(data: data, isCacheable: false)
        case nil:
            break
        }
        let generation = state.withLock { $0.signedGeneration }
        let result: ImageFetchResult
        do {
            result = try await fetcher.fetchImage(for: url, context: context)
        } catch {
            if !Task.isCancelled, Self.isDefiniteFailure(error) {
                remember(.failed(until: clock.now.addingTimeInterval(negativeLifetime), error: error), for: key.media)
            }
            throw error
        }
        coordinator?.recordTransfer(bytes: result.data.count, priority: context.priority)
        try Task.checkCancellation()
        audit("network", key)
        if result.isCacheable {
            // P2 bytes were never shown: speculative until a decode reads them.
            let tier: CacheTier = context.priority == .speculative ? .speculative : .recent
            writeToDisk(result.data, for: key, in: stores, tier: tier, generation: generation)
        } else {
            // ⚠️ Never under the real key: a fetcher's fallback stands in for
            // `negativeLifetime`, then the real image is asked for again.
            remember(.placeholder(until: clock.now.addingTimeInterval(negativeLifetime), data: result.data), for: key.media)
        }
        return result
    }

    private func diskData(for key: ImageKey, in disks: ImageDisks?) -> Data? {
        guard let disks else { return nil }
        if key.isSigned { return disks.signed.data(for: key.media) }
        let order = key.bucket.isSmall ? [disks.small, disks.common] : [disks.common, disks.small]
        for store in order where store.contains(key.media) {
            if let data = store.data(for: key.media) { return data }
        }
        return nil
    }

    private func writeToDisk(_ data: Data, for key: ImageKey, in disks: ImageDisks?, tier: CacheTier, generation: Int) {
        guard let disks else { return }
        let store: DiskStore
        if key.isSigned {
            store = disks.signed
        } else {
            // One encoded copy: never a second one in the other public store.
            if disks.common.contains(key.media) || disks.small.contains(key.media) { return }
            store = key.bucket.isSmall ? disks.small : disks.common
        }
        _ = try? store.write(data, for: key.media, tier: tier)
        if key.isSigned, state.withLock({ $0.signedGeneration }) != generation {
            // The viewer changed while it downloaded: not this viewer's to keep.
            store.removeValue(for: key.media)
        }
    }

    private func removeFromDisk(_ key: ImageKey, in disks: ImageDisks?) {
        guard let disks else { return }
        for store in [disks.common, disks.small, disks.signed] {
            store.removeValue(for: key.media)
        }
    }

    private func rememberedOutcome(for media: String) -> Negative? {
        let now = clock.now
        return state.withLock { state in
            guard let entry = state.negative[media] else { return nil }
            guard entry.until > now else {
                state.negative[media] = nil
                return nil
            }
            return entry
        }
    }

    private func remember(_ outcome: Negative, for media: String) {
        let now = clock.now
        state.withLock { state in
            // Sweeps the expired ones, so the table stays small.
            if state.negative.count >= 256 { state.negative = state.negative.filter { $0.value.until > now } }
            state.negative[media] = outcome
        }
    }

    /// A logout or a profile switch wiped the signed disk namespace: its
    /// decoded images go too, and fills in flight store nothing.
    private func signedMediaWiped() {
        let keys = state.withLock { state -> Set<ImageKey> in
            state.signedGeneration += 1
            let taken = state.signedKeys
            state.signedKeys = []
            state.negative = [:]
            return taken
        }
        for key in keys { cache(for: key.bucket).removeValue(for: key) }
    }

    /// Errors that a retry a moment later would meet again: remembered for
    /// `negativeLifetime`. Connectivity errors and cancellations are not: the
    /// next request retries at once.
    static func isDefiniteFailure(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .badServerResponse, .cannotDecodeContentData, .cannotDecodeRawData, .cannotParseResponse,
             .zeroByteResource, .badURL, .unsupportedURL, .fileDoesNotExist, .resourceUnavailable,
             .noPermissionsToReadFile:
            return true
        default:
            return false
        }
    }

    // MARK: - Decoding

    static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Decodes `data` at `bucket`: a small bucket's SHORT side reaches the
    /// bucket (aspect fill), never past `maxPixelSize`; `full` is
    /// `maxPixelSize` on the long side. Never upscales.
    static func decode(_ data: Data, bucket: ImageBucket, maxPixelSize: Int) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        var limit = maxPixelSize
        if let pixels = bucket.pixels {
            limit = min(pixels, maxPixelSize)
            if let size = pixelSize(of: source), size.short > 0 {
                let covering = (Double(pixels) * Double(size.long) / Double(size.short)).rounded(.up)
                limit = min(maxPixelSize, max(pixels, Int(min(covering, Double(Int.max / 2)))))
            }
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: cgImage)
    }

    private static func pixelSize(of source: CGImageSource) -> (long: Int, short: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (max(width, height), min(width, height))
    }

    // MARK: - Audit

    /// `-cache-audit` (DEBUG): one line per image that came from the disk or
    /// the network, so a relaunch shows the disk serving what was seen.
    /// Counts what an image found when it reached the screen, once per image
    /// per stay (`ImageArrivals`). DEBUG only: the ledger is a set lookup on
    /// every cell configuration.
    private func recordArrival(_ key: ImageKey, _ arrival: CachePrefetchCounters.Arrival) {
        #if DEBUG
        guard let coordinator, arrivals.isFirstArrival(of: key) else { return }
        coordinator.prefetchCounters.recordArrival(.images, arrival)
        #endif
    }

    private func audit(_ source: StaticString, _ key: ImageKey) {
        #if DEBUG
        if Self.audits {
            print("[cache-audit] image \(source) \(key.bucket) \(key.media)")
        }
        #endif
    }

    #if DEBUG
    private static let audits = ProcessInfo.processInfo.arguments.contains("-cache-audit")
    #endif
}

/// The memory key: one media at one bucket.
struct ImageKey: Hashable, Sendable {
    let media: String
    let bucket: ImageBucket
    /// Fetched through a signed URL: wiped with the viewer.
    let isSigned: Bool

    init(media: String, bucket: ImageBucket, isSigned: Bool) {
        self.media = media
        self.bucket = bucket
        self.isSigned = isSigned
    }

    init(url: URL, bucket: ImageBucket) {
        // Most URLs carry no query: no parse on the cell-configuration path.
        if url.query == nil, url.fragment == nil {
            self.init(media: url.absoluteString, bucket: bucket, isSigned: false)
        } else {
            self.init(media: CacheKey.media(url), bucket: bucket, isSigned: CacheKey.isSigned(url))
        }
    }

    static func == (lhs: ImageKey, rhs: ImageKey) -> Bool {
        lhs.media == rhs.media && lhs.bucket == rhs.bucket
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(media)
        hasher.combine(bucket)
    }
}

/// The three disk namespaces of the images pool.
private struct ImageDisks: Sendable {
    let common: DiskStore
    let small: DiskStore
    let signed: DiskStore
    /// Never `true` in the app: the pipeline opens its stores on a utility task.
    let openedOnMainThread: Bool

    init?(location: ImageDiskLocation, clock: any CacheClock) {
        openedOnMainThread = Thread.isMainThread
        let root: URL? = switch location {
        case .caches: nil
        case .folder(let url): url
        }
        do {
            common = try DiskStore(
                namespace: ImagePipeline.Namespaces.disk,
                budget: DiskBudget(pool: .images, weight: ImagePipeline.publicDiskWeight),
                root: root, clock: clock
            )
            small = try DiskStore(
                namespace: ImagePipeline.Namespaces.diskSmall,
                budget: .reserved(ImagePipeline.smallDiskFloor, in: .images),
                root: root, clock: clock
            )
            signed = try DiskStore(
                namespace: ImagePipeline.Namespaces.diskSigned,
                budget: SignedImageDisk.diskBudget,
                root: root, clock: clock
            )
        } catch {
            #if DEBUG
            print("[images] disk cache unavailable, memory only: \(error)")
            #endif
            return nil
        }
    }
}

#if DEBUG
/// The images that arrived recently, so an image counts once per stay on
/// screen: a cell's synchronous check, its configuration and the async load
/// that follows a miss are one arrival. An image scrolled far away and back
/// (out of the last `capacity`) counts again.
private final class ImageArrivals: Sendable {
    static let capacity = 512

    private struct State {
        var seen: Set<ImageKey> = []
        var order: [ImageKey] = []
        var next = 0
    }

    private let state = Mutex(State())

    func isFirstArrival(of key: ImageKey) -> Bool {
        state.withLock { state in
            guard state.seen.insert(key).inserted else { return false }
            if state.order.count < Self.capacity {
                state.order.append(key)
            } else {
                state.seen.remove(state.order[state.next])
                state.order[state.next] = key
                state.next = (state.next + 1) % Self.capacity
            }
            return true
        }
    }
}
#endif

/// The signed namespace as the coordinator sees it, registered before its
/// `DiskStore` has opened: limits and a wipe that arrive meanwhile are kept
/// and applied to the store when it attaches. A wipe (a logout, a profile
/// switch, a Settings clear) also drops the pipeline's decoded copies of
/// signed media.
private final class SignedImageDisk: ManagedCache {
    static let diskBudget = DiskBudget(pool: .images, weight: ImagePipeline.signedDiskWeight)

    private struct State {
        var store: DiskStore?
        var limits: (CacheLimits, CacheEvictionReason)?
        var wipePending: CacheEvictionReason?
    }

    private let state = Mutex(State())
    private let onRemoveAll = Mutex<(@Sendable () -> Void)?>(nil)

    func setOnRemoveAll(_ handler: @escaping @Sendable () -> Void) {
        onRemoveAll.withLock { $0 = handler }
    }

    /// The store opened: what arrived before it is applied now.
    func attach(_ store: DiskStore) {
        let pending = state.withLock { state -> ((CacheLimits, CacheEvictionReason)?, CacheEvictionReason?) in
            state.store = store
            let taken = (state.limits, state.wipePending)
            state.wipePending = nil
            return taken
        }
        if let limits = pending.0 { store.setLimits(limits.0, reason: limits.1) }
        if let reason = pending.1 { store.removeAll(reason: reason) }
    }

    private var store: DiskStore? { state.withLock { $0.store } }

    var namespace: CacheNamespace { ImagePipeline.Namespaces.diskSigned }
    var budget: CacheBudget { .disk(Self.diskBudget) }
    var usage: CacheUsage { store?.usage ?? CacheUsage(byteLimit: state.withLock { $0.limits?.0.bytes ?? .max }) }
    var statistics: CacheStatistics { store?.statistics ?? CacheStatistics() }
    func trim(_ depth: TrimDepth) { trim(depth, reason: .trim) }
    func trim(_ depth: TrimDepth, reason: CacheEvictionReason) { store?.trim(depth, reason: reason) }
    func flush() { store?.flush() }

    func setLimits(_ limits: CacheLimits) {
        setLimits(limits, reason: .budget)
    }

    func setLimits(_ limits: CacheLimits, reason: CacheEvictionReason) {
        let attached = state.withLock { state -> DiskStore? in
            state.limits = (limits, reason)
            return state.store
        }
        attached?.setLimits(limits, reason: reason)
    }

    func removeAll() {
        removeAll(reason: .wipe)
    }

    func removeAll(reason: CacheEvictionReason) {
        let attached = state.withLock { state -> DiskStore? in
            if state.store == nil { state.wipePending = reason }
            return state.store
        }
        attached?.removeAll(reason: reason)
        let handler = onRemoveAll.withLock { $0 }
        handler?()
    }
}
