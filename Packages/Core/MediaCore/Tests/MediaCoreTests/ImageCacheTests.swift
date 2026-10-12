import CacheKit
import Foundation
import Synchronization
import Testing
import UIKit
@testable import MediaCore

// MARK: - Support

/// A PNG of `width` × `height` pixels.
private func png(width: Int, height: Int) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
        UIColor.orange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// Serves a PNG sized by the URL's `w`/`h` (256 by default), counts fetches,
/// and can fail, or hold every fetch until `open()`.
private final class ScriptedFetcher: ImageFetching {
    private struct FetchWaiter {
        let url: String?
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var fetches: [String: Int] = [:]
        var failure: URLError?
        var isHeld = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var fetchWaiters: [FetchWaiter] = []

        func count(of url: String?) -> Int {
            url.map { fetches[$0] ?? 0 } ?? fetches.values.reduce(0, +)
        }

        /// Takes out the waiters whose count is reached.
        mutating func reached() -> [CheckedContinuation<Void, Never>] {
            var ready: [CheckedContinuation<Void, Never>] = []
            var waiting: [FetchWaiter] = []
            for waiter in fetchWaiters {
                if count(of: waiter.url) >= waiter.count {
                    ready.append(waiter.continuation)
                } else {
                    waiting.append(waiter)
                }
            }
            fetchWaiters = waiting
            return ready
        }
    }

    private let state = Mutex(State())

    init(failure: URLError? = nil, held: Bool = false) {
        state.withLock {
            $0.failure = failure
            $0.isHeld = held
        }
    }

    var fetchCount: Int { state.withLock { $0.fetches.values.reduce(0, +) } }

    func fetchCount(for url: URL) -> Int { state.withLock { $0.fetches[url.absoluteString] ?? 0 } }

    func setFailure(_ failure: URLError?) { state.withLock { $0.failure = failure } }

    /// Returns once `count` fetches of `url` (of any image when `nil`) have
    /// begun. A prefetch's fill runs at utility QoS and can start long after
    /// any look budget on a loaded runner (#1049): a test awaits its fetch
    /// instead of polling for it.
    func fetchesBegan(_ count: Int = 1, of url: URL? = nil) async {
        let key = url?.absoluteString
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isReached = state.withLock { state -> Bool in
                guard state.count(of: key) < count else { return true }
                state.fetchWaiters.append(FetchWaiter(url: key, count: count, continuation: continuation))
                return false
            }
            if isReached { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isHeld = false
            let taken = state.waiters
            state.waiters = []
            return taken
        }
        for waiter in waiters { waiter.resume() }
    }

    func fetchImageData(for url: URL) async throws -> Data {
        let began = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fetches[url.absoluteString, default: 0] += 1
            return state.reached()
        }
        for waiter in began { waiter.resume() }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard state.isHeld else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        if let failure = state.withLock({ $0.failure }) { throw failure }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let width = items.first { $0.name == "w" }.flatMap { Int($0.value ?? "") } ?? 256
        let height = items.first { $0.name == "h" }.flatMap { Int($0.value ?? "") } ?? 256
        return png(width: width, height: height)
    }
}

/// A private folder, deleted with the suite instance.
private final class Folder: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ImageCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

private func device(memory: UInt64 = 4 << 30) -> CacheDevice {
    CacheDevice(physicalMemory: { memory }, availableDiskCapacity: { 100 * Int64(CacheBytes.gigabyte) })
}

/// A look budget, not a deadline (#966, #980): stops as soon as `condition`
/// holds, so the budget only matters on a starved runner.
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<6_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func pixels(_ image: UIImage) -> CGSize {
    CGSize(width: image.cgImage?.width ?? 0, height: image.cgImage?.height ?? 0)
}

// MARK: - Decode at display size

struct ImageBucketTests {
    @Test func anAvatarIsDecodedAtItsBucketNotAtFullSize() async throws {
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher())
        let url = try #require(URL(string: "mock://avatar/1?w=1600&h=1600"))

        let small = try await pipeline.image(for: url, size: .avatar)
        let large = try await pipeline.image(for: url)

        #expect(pixels(small) == CGSize(width: 128, height: 128))
        #expect(pixels(large) == CGSize(width: 1200, height: 1200))
    }

    @Test func aSmallBucketCoversItsSquareWithTheShortSide() async throws {
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher())
        let url = try #require(URL(string: "mock://photo/2?w=1600&h=1200"))

        let image = try await pipeline.image(for: url, size: .px256)

        let size = pixels(image)
        #expect((256...257).contains(size.height), "the short side reaches the bucket: aspect fill stays sharp (\(size))")
        #expect(size.width == 342)
    }

    @Test func aBucketFitsTheViewItIsShownIn() {
        #expect(ImageBucket(fitting: CGSize(width: 40, height: 40), scale: 3) == .px128)
        #expect(ImageBucket(fitting: CGSize(width: 20, height: 20), scale: 3) == .px64)
        #expect(ImageBucket(fitting: CGSize(width: 120, height: 160), scale: 3) == .px512)
        #expect(ImageBucket(fitting: CGSize(width: 390, height: 844), scale: 3) == .full)
        #expect(ImageBucket.avatar.isSmall && !ImageBucket.px256.isSmall)
    }

    @Test func aLargerDecodedBucketServesASmallerLookupAndNeverTheReverse() async throws {
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher())
        let big = try #require(URL(string: "mock://photo/3?w=1600&h=1600"))
        let small = try #require(URL(string: "mock://photo/4?w=1600&h=1600"))

        _ = try await pipeline.image(for: big)
        _ = try await pipeline.image(for: small, size: .px64)

        #expect(pipeline.cachedImage(for: big, size: .avatar).map(pixels) == CGSize(width: 1200, height: 1200))
        #expect(pipeline.cachedImage(for: small) == nil, "a 64 px decode never stands in for a full one")
    }

    @Test func everyBucketOfOneMediaSharesOneDownload() async throws {
        let fetcher = ScriptedFetcher(held: true)
        let pipeline = ImagePipeline(fetcher: fetcher)
        let url = try #require(URL(string: "mock://photo/5?w=800&h=800"))

        async let small = pipeline.image(for: url, size: .avatar)
        async let large = pipeline.image(for: url)
        #expect(await eventually { pipeline.downloadInterestCount(for: url) == 2 }, "both decodes wait on one download")
        fetcher.open()
        _ = try await (small, large)

        #expect(fetcher.fetchCount == 1)
    }
}

// MARK: - Memory budget

struct ImageMemoryBudgetTests {
    @Test func decodedImagesStayWithinTheirByteBudget() async throws {
        // 64 px square bitmaps cost 64 × 64 × 4 bytes; room for three.
        let cost = 64 * 64 * 4
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), memoryLimit: 3 * cost)
        for index in 0..<10 {
            let url = try #require(URL(string: "mock://avatar/\(index)?w=64&h=64"))
            _ = try await pipeline.image(for: url, size: .px64)
            #expect(pipeline.decodedUsage.bytes <= 3 * cost)
        }
        #expect(pipeline.decodedUsage.count == 3)
    }

    @Test func theCoordinatorSizesEveryNamespaceFromTheDevice() async throws {
        let folder = Folder()
        let coordinator = CacheCoordinator(device: device(memory: 4 << 30))
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
        await pipeline.waitUntilDiskIsOpen()
        let report = coordinator.usage()

        let decoded = try #require(report.usage(of: "images.decoded", medium: .memory))
        #expect(decoded.byteLimit == MemoryBudget.decodedImages.bytes(physicalMemory: 4 << 30))
        let smallDecoded = try #require(report.usage(of: "images.decoded.small", medium: .memory))
        #expect(smallDecoded.byteLimit == ImagePipeline.smallDecodedBudget.bytes(physicalMemory: 4 << 30))
        let smallDisk = try #require(report.usage(of: "images.small", medium: .disk))
        #expect(smallDisk.byteLimit == 30 * CacheBytes.megabyte, "the avatars' floor")
        let common = try #require(report.usage(of: "images", medium: .disk))
        let signed = try #require(report.usage(of: "images.signed", medium: .disk))
        #expect(common.byteLimit + signed.byteLimit + smallDisk.byteLimit <= DiskPool.images.automaticBytes)
        #expect(common.byteLimit > signed.byteLimit)
        withExtendedLifetime(pipeline) {}
    }
}

// MARK: - Disk

struct ImageDiskCacheTests {
    private let folder = Folder()

    @Test func imagesSeenBeforeARelaunchRenderFromDiskOffline() async throws {
        let url = try #require(URL(string: "https://cdn.test/photo/6.png?w=600&h=400"))
        do {
            let coordinator = CacheCoordinator(device: device())
            let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
            _ = try await pipeline.image(for: url)
            #expect(pipeline.isOnDisk(url))
            // The app going to the background flushes the disk indexes.
            coordinator.trim(.background)
        }

        // The next launch, in airplane mode.
        let offline = ScriptedFetcher(failure: URLError(.notConnectedToInternet))
        let relaunched = ImagePipeline(fetcher: offline, disk: .folder(folder.url), coordinator: CacheCoordinator(device: device()))
        let image = try await relaunched.image(for: url)

        #expect(pixels(image) == CGSize(width: 600, height: 400))
        #expect(offline.fetchCount == 0)
    }

    /// The composition root builds the pipeline on the main thread: opening
    /// its stores (folders, index, reconciliation with the files) must not
    /// happen there, whatever reads first.
    @MainActor
    @Test func theDiskIsNeverOpenedOnTheMainThread() async throws {
        let url = try #require(URL(string: "https://cdn.test/photo/30.png"))
        do {
            let coordinator = CacheCoordinator(device: device())
            let first = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
            _ = try await first.image(for: url)
            coordinator.trim(.background)
            // Asked on the main thread, the background's index flush runs on
            // the coordinator's queue (#898).
            coordinator.waitForDiskWork()
        }

        // Built, and read first, on the main thread.
        let offline = ScriptedFetcher(failure: URLError(.notConnectedToInternet))
        let pipeline = ImagePipeline(fetcher: offline, disk: .folder(folder.url))
        _ = pipeline.isOnDisk(url)
        _ = pipeline.cachedImage(for: url)
        let image = try await pipeline.image(for: url)

        #expect(pipeline.diskOpenedOnMainThread == false, "opened on a utility task")
        #expect(pixels(image).width > 0 && offline.fetchCount == 0, "and served from disk once open")
    }

    @Test func avatarsAndSmallThumbnailsLandInTheirOwnNamespace() async throws {
        let coordinator = CacheCoordinator(device: device())
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
        let avatar = try #require(URL(string: "https://cdn.test/avatar/7.png"))
        let photo = try #require(URL(string: "https://cdn.test/photo/8.png"))

        _ = try await pipeline.image(for: avatar, size: .avatar)
        _ = try await pipeline.image(for: photo)

        let report = coordinator.usage()
        #expect(report.usage(of: "images.small", medium: .disk)?.count == 1)
        #expect(report.usage(of: "images", medium: .disk)?.count == 1)
        #expect(report.usage(of: "images.decoded.small", medium: .memory)?.count == 1)
        #expect(report.usage(of: "images.decoded", medium: .memory)?.count == 1)
        #expect(pipeline.isOnDisk(avatar) && pipeline.isOnDisk(photo))
    }

    @Test func aSignedURLIsOneEntryWhateverItsSignature() async throws {
        let fetcher = ScriptedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url))
        let first = try #require(URL(string: "https://cdn.test/private/9.png?X-Amz-Signature=aaa&X-Amz-Expires=60"))
        let second = try #require(URL(string: "https://cdn.test/private/9.png?X-Amz-Signature=bbb&X-Amz-Expires=60"))

        _ = try await pipeline.image(for: first)
        _ = try await pipeline.image(for: second)

        #expect(fetcher.fetchCount == 1)
        #expect(pipeline.cachedImage(for: second) != nil)
    }

    @Test func aLogoutWipesSignedMediaAndKeepsPublicMedia() async throws {
        let coordinator = CacheCoordinator(device: device())
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
        let signed = try #require(URL(string: "https://cdn.test/private/10.png?X-Amz-Signature=aaa&X-Amz-Expires=60"))
        let avatar = try #require(URL(string: "https://cdn.test/private/11.png?X-Amz-Signature=aaa"))
        let open = try #require(URL(string: "https://cdn.test/public/12.png"))
        _ = try await pipeline.image(for: signed)
        _ = try await pipeline.image(for: avatar, size: .avatar)
        _ = try await pipeline.image(for: open)

        coordinator.trim(.viewerChanged)

        #expect(pipeline.cachedImage(for: signed) == nil && !pipeline.isOnDisk(signed))
        #expect(pipeline.cachedImage(for: avatar, size: .avatar) == nil && !pipeline.isOnDisk(avatar))
        #expect(pipeline.cachedImage(for: open) != nil && pipeline.isOnDisk(open))
    }

    /// The stores open on a utility task; a logout that lands before the
    /// open has finished still wipes signed media once it has.
    @Test func aLogoutDuringTheDiskOpenStillWipesSignedMedia() async throws {
        let signed = try #require(URL(string: "https://cdn.test/private/31.png?X-Amz-Signature=aaa"))
        let open = try #require(URL(string: "https://cdn.test/public/32.png"))
        do {
            let coordinator = CacheCoordinator(device: device())
            let first = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
            _ = try await first.image(for: signed)
            _ = try await first.image(for: open)
            coordinator.trim(.background)
        }

        let coordinator = CacheCoordinator(device: device())
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
        coordinator.trim(.viewerChanged)
        await pipeline.waitUntilDiskIsOpen()

        #expect(!pipeline.isOnDisk(signed), "the wipe waited for the store")
        #expect(pipeline.isOnDisk(open))
    }

    @Test func aSettingsClearOfImagesEmptiesMemoryAndDisk() async throws {
        let coordinator = CacheCoordinator(device: device())
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
        let url = try #require(URL(string: "https://cdn.test/public/13.png"))
        _ = try await pipeline.image(for: url)

        coordinator.trim(.clear(.images))

        #expect(pipeline.cachedImage(for: url) == nil)
        #expect(!pipeline.isOnDisk(url))
    }
}

// MARK: - Failures

struct ImageFailureTests {
    private let clock = ManualCacheClock()

    @Test func aPlaceholderIsNeverStoredUnderTheRealKey() async throws {
        let folder = Folder()
        let remote = ScriptedFetcher(failure: URLError(.timedOut))
        let fetcher = SchemeRoutingImageFetcher(remote: remote, placeholder: PlaceholderImageFetcher())
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url), clock: clock)
        let url = try #require(URL(string: "https://cdn.test/dead/14.png"))

        let stand = try await pipeline.image(for: url)

        #expect(pixels(stand).width > 0, "the post stays visible")
        #expect(pipeline.cachedImage(for: url) == nil, "not in memory under the real key")
        #expect(!pipeline.isOnDisk(url), "not on disk under the real key")

        _ = try await pipeline.image(for: url)
        #expect(remote.fetchCount == 1, "the stand-in answers for the negative lifetime")

        remote.setFailure(nil)
        clock.advance(by: ImagePipeline.defaultNegativeLifetime + 1)
        let real = try await pipeline.image(for: url)
        #expect(remote.fetchCount == 2, "then the real image is asked for again")
        #expect(pipeline.cachedImage(for: url) === real)
        #expect(pipeline.isOnDisk(url))
    }

    @Test func aDefiniteFailureIsRetriedAfterTheNegativeLifetime() async throws {
        let fetcher = ScriptedFetcher(failure: URLError(.badServerResponse))
        let pipeline = ImagePipeline(fetcher: fetcher, clock: clock)
        let url = try #require(URL(string: "https://cdn.test/missing/15.png"))

        await #expect(throws: URLError.self) { try await pipeline.image(for: url) }
        await #expect(throws: URLError.self) { try await pipeline.image(for: url) }
        #expect(fetcher.fetchCount == 1, "remembered: no second request meanwhile")

        fetcher.setFailure(nil)
        clock.advance(by: ImagePipeline.defaultNegativeLifetime + 1)
        _ = try await pipeline.image(for: url)
        #expect(fetcher.fetchCount == 2)
    }

    @Test func aConnectivityFailureIsRetriedAtOnce() async throws {
        let fetcher = ScriptedFetcher(failure: URLError(.notConnectedToInternet))
        let pipeline = ImagePipeline(fetcher: fetcher, clock: clock)
        let url = try #require(URL(string: "https://cdn.test/offline/16.png"))

        await #expect(throws: URLError.self) { try await pipeline.image(for: url) }
        fetcher.setFailure(nil)
        _ = try await pipeline.image(for: url)

        #expect(fetcher.fetchCount == 2)
    }
}

// MARK: - Prefetch (#970)

struct ImagePrefetchTests {
    private let folder = Folder()

    @Test func aDisplayWindowPrefetchDecodesAtItsBucket() async throws {
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher())
        let owner = CacheOwner("grid")
        let url = try #require(URL(string: "mock://photo/17?w=1600&h=1600"))

        let interest = pipeline.prefetch(url, size: .px256, window: .display, owner: owner)

        #expect(interest != nil)
        #expect(await pipeline.prefetchLanded(url, size: .px256, window: .display))
        #expect(!pipeline.isDecoded(url), "decoded at its bucket only")
        #expect(pipeline.prefetch(url, size: .px256, window: .display, owner: owner) == nil, "already there")
        withExtendedLifetime((owner, interest)) {}
    }

    @Test func aPreloadWindowPrefetchWritesBytesWithoutDecoding() async throws {
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url))
        let owner = CacheOwner("grid")
        let url = try #require(URL(string: "https://cdn.test/photo/18.png"))

        let interest = pipeline.prefetch(url, window: .preload, owner: owner)

        #expect(await pipeline.prefetchLanded(url, window: .preload))
        #expect(!pipeline.isDecoded(url, size: .px64), "no decode in the preload window")
        #expect(pipeline.prefetch(url, window: .preload, owner: owner) == nil)
        withExtendedLifetime((owner, interest)) {}
    }

    @Test func aPreloadWaitsForASpeculativeSlotAndAVisibleLoadPromotesIt() async throws {
        let coordinator = CacheCoordinator(device: device())
        let fetcher = ScriptedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url), coordinator: coordinator)
        let owner = CacheOwner("grid")
        let preloaded = try #require(URL(string: "https://cdn.test/photo/19.png"))
        let displayed = try #require(URL(string: "https://cdn.test/photo/20.png"))
        // A playing video is under-buffered: no P2 starts anywhere.
        coordinator.setPlaybackUnderBuffered(true)

        let waiting = pipeline.prefetch(preloaded, window: .preload, owner: owner)
        let next = pipeline.prefetch(displayed, window: .display, owner: owner)

        #expect(await pipeline.prefetchLanded(displayed, window: .display), "P1 never waits for a slot")
        #expect(fetcher.fetchCount(for: preloaded) == 0, "P2 waits")

        _ = try await pipeline.image(for: preloaded)
        #expect(fetcher.fetchCount(for: preloaded) == 1, "a visible load joins and starts it")
        coordinator.setPlaybackUnderBuffered(false)
        withExtendedLifetime((owner, waiting, next)) {}
    }

    @Test func aVisibleLoadAndAPrefetchShareOneFetch() async throws {
        let fetcher = ScriptedFetcher(held: true)
        let pipeline = ImagePipeline(fetcher: fetcher)
        let owner = CacheOwner("grid")
        let url = try #require(URL(string: "mock://photo/21"))

        // The visible load first, so it is surely waiting before the revoke.
        let visible = Task { try await pipeline.image(for: url) }
        await fetcher.fetchesBegan()
        pipeline.prefetch(url, window: .display, owner: owner)
        owner.revoke()
        fetcher.open()
        _ = try await visible.value

        #expect(fetcher.fetchCount == 1, "the prefetch's revoke left the visible load running")
    }

    @Test func aPrefetchNobodyElseWantsIsCancelledWithItsOwner() async throws {
        let fetcher = ScriptedFetcher(held: true)
        let pipeline = ImagePipeline(fetcher: fetcher)
        let owner = CacheOwner("grid")
        let url = try #require(URL(string: "mock://photo/22"))

        pipeline.prefetch(url, window: .display, owner: owner)
        await fetcher.fetchesBegan()
        owner.revoke()

        #expect(pipeline.inFlightCount == 0)
        fetcher.open()
    }
}

struct ImageLookaheadTests {
    private let folder = Folder()

    @Test func twoListsShareOneFetchAndItSurvivesUntilTheLastLeaves() async throws {
        let fetcher = ScriptedFetcher(held: true)
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url))
        let feed = ImageLookahead(pipeline: pipeline, name: "feed")
        let grid = ImageLookahead(pipeline: pipeline, name: "grid")
        let request = try ImageRequest(url: #require(URL(string: "https://cdn.test/shared/23.png")))

        feed.update(display: [], preload: [request])
        grid.update(display: [], preload: [request])
        await fetcher.fetchesBegan()

        feed.revoke()
        #expect(pipeline.inFlightCount == 1, "still wanted by the grid")
        grid.revoke()
        #expect(pipeline.inFlightCount == 0, "nobody left: cancelled")
        fetcher.open()
        #expect(fetcher.fetchCount == 1)
    }

    @Test func leavingTheWindowsReleasesAndAnotherListKeepsItsShare() async throws {
        let fetcher = ScriptedFetcher(held: true)
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url))
        let feed = ImageLookahead(pipeline: pipeline, name: "feed")
        let mine = try ImageRequest(url: #require(URL(string: "https://cdn.test/only/24.png")))
        let shared = try ImageRequest(url: #require(URL(string: "https://cdn.test/shared/25.png")))
        let grid = ImageLookahead(pipeline: pipeline, name: "grid")
        // The display window, so neither waits for a speculative slot.
        feed.update(display: [mine, shared], preload: [])
        grid.update(display: [shared], preload: [])
        await fetcher.fetchesBegan(2)

        feed.update(display: [], preload: [])

        #expect(feed.window(of: mine) == nil)
        #expect(pipeline.inFlightCount == 2, "the grid's decode and its download are left")
        fetcher.open()
        #expect(await pipeline.prefetchLanded(shared.url, window: .display))
        #expect(!pipeline.isDecoded(mine.url))
        grid.revoke()
    }

    @Test func aFlingDownloadsTheDisplayWindowAndDecodesOnceItSlows() async throws {
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url))
        let grid = ImageLookahead(pipeline: pipeline, name: "grid")
        let request = try ImageRequest(url: #require(URL(string: "https://cdn.test/fling/26.png")), size: .px256)

        grid.setFlinging(true)
        grid.update(display: [request], preload: [])
        #expect(grid.window(of: request) == .preload)
        #expect(await pipeline.prefetchLanded(request.url, window: .preload))
        #expect(!pipeline.isDecoded(request.url, size: .px256))

        grid.setFlinging(false)
        #expect(grid.window(of: request) == .display)
        #expect(await pipeline.prefetchLanded(request.url, size: .px256, window: .display))
        #expect(ImageLookahead.isFling(velocity: 4_000, viewportLength: 800))
        #expect(!ImageLookahead.isFling(velocity: 1_000, viewportLength: 800))
    }

    @Test func movingFromPreloadToDisplayKeepsTheDownloadRunning() async throws {
        let fetcher = ScriptedFetcher(held: true)
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url))
        let grid = ImageLookahead(pipeline: pipeline, name: "grid")
        let request = try ImageRequest(url: #require(URL(string: "https://cdn.test/near/27.png")))

        grid.update(display: [], preload: [request])
        await fetcher.fetchesBegan()
        grid.update(display: [request], preload: [])
        fetcher.open()

        #expect(await pipeline.prefetchLanded(request.url, window: .display))
        #expect(fetcher.fetchCount == 1, "the decode joined the download in flight")
        grid.revoke()
    }

    @Test func aHiddenListOnlyDownloadsAtSpeculativePriority() async throws {
        let coordinator = CacheCoordinator(device: device())
        let fetcher = ScriptedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url), coordinator: coordinator)
        let grid = ImageLookahead(pipeline: pipeline, name: "grid")
        let request = try ImageRequest(url: #require(URL(string: "https://cdn.test/hidden/28.png")))
        coordinator.setPlaybackUnderBuffered(true)

        grid.setHidden(true)
        grid.update(display: [request], preload: [])

        #expect(grid.window(of: request) == .preload, "no decode while hidden")
        try await Task.sleep(for: .milliseconds(50))
        #expect(fetcher.fetchCount == 0, "P2 at most: it waits like any speculative fill")
        coordinator.setPlaybackUnderBuffered(false)
        #expect(await pipeline.prefetchLanded(request.url, window: .preload))
        grid.revoke()
    }

    @Test func theWindowsFollowThePolicyAndTheScrollDirection() {
        let wifi = LookaheadWindow.windows(for: .full)
        #expect(wifi.display == .display && wifi.preload == .preload)
        let lowData = LookaheadWindow.windows(for: .reduced)
        #expect(lowData.preload == .none, "Low Data / Low Power: no P2")
        #expect(lowData.display == .display)
        let hidden = LookaheadWindow.windows(for: .full, isHidden: true)
        #expect(hidden.display == .hiddenDisplay && hidden.preload == .hiddenPreload)

        let visible = CGRect(x: 0, y: 1_000, width: 400, height: 800)
        let down = LookaheadWindow.display.rect(around: visible, axis: .vertical, forward: true)
        #expect(down == CGRect(x: 0, y: 600, width: 400, height: 2_000))
        let up = LookaheadWindow.display.rect(around: visible, axis: .vertical, forward: false)
        #expect(up == CGRect(x: 0, y: 200, width: 400, height: 2_000))
        let rail = LookaheadWindow.preload.rect(around: CGRect(x: 0, y: 0, width: 100, height: 50), axis: .horizontal)
        #expect(rail == CGRect(x: -150, y: 0, width: 500, height: 50))
    }
}

// MARK: - `-cache-audit` counters (#900)

struct ImageAuditCounterTests {
    private let folder = Folder()

    @Test func eachImageCountsOnceWhenItArrivesReadyInFlightOrMissed() async throws {
        let coordinator = CacheCoordinator(device: device())
        let fetcher = ScriptedFetcher(held: true)
        let pipeline = ImagePipeline(fetcher: fetcher, coordinator: coordinator)
        let owner = CacheOwner("grid")
        let joined = try #require(URL(string: "mock://photo/41"))
        let cold = try #require(URL(string: "mock://photo/42"))
        let prefetched = try #require(URL(string: "mock://photo/43"))

        // Two display prefetches (P1, utility QoS): awaited, never polled
        // under a look budget a loaded runner outlasts (#1049).
        let joinedInterest = pipeline.prefetch(joined, window: .display, owner: owner)
        let prefetchedInterest = pipeline.prefetch(prefetched, window: .display, owner: owner)
        await fetcher.fetchesBegan(of: joined)
        await fetcher.fetchesBegan(of: prefetched)
        let joining = Task { try await pipeline.image(for: joined) }
        let missing = Task { try await pipeline.image(for: cold) }
        await fetcher.fetchesBegan(of: cold)
        // The visible load counts on arrival, while the prefetch is still out.
        #expect(await eventually { coordinator.prefetchCounters.snapshot.arrivals[.images]?.inFlight == 1 })
        fetcher.open()
        _ = try await joining.value
        _ = try await missing.value

        #expect(await pipeline.prefetchLanded(prefetched, window: .display))
        #expect(fetcher.fetchCount(for: prefetched) == 1, "decoded by the prefetch's own fetch")
        #expect(pipeline.cachedImage(for: prefetched) != nil)
        // The same images again, by both paths: still one arrival each.
        #expect(pipeline.cachedImage(for: cold) != nil)
        _ = try await pipeline.image(for: joined)

        let arrivals = try #require(coordinator.prefetchCounters.snapshot.arrivals[.images])
        #expect(arrivals.ready == 1)
        #expect(arrivals.inFlight == 1)
        #expect(arrivals.missed == 1)
        withExtendedLifetime((owner, joinedInterest, prefetchedInterest)) {}
    }

    @Test func networkBytesAreCountedPerPriorityAndNetwork() async throws {
        let coordinator = CacheCoordinator(device: device())
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
        await pipeline.waitUntilDiskIsOpen()
        let shown = try #require(URL(string: "https://cdn.test/audit/44.png"))
        let preloaded = try #require(URL(string: "https://cdn.test/audit/45.png"))

        _ = try await pipeline.image(for: shown)
        coordinator.handle(.network(.cellular, isConstrained: false, isExpensive: true))
        let owner = CacheOwner("feed")
        let interest = pipeline.prefetch(preloaded, window: .preload, owner: owner)
        #expect(await pipeline.prefetchLanded(preloaded, window: .preload))
        withExtendedLifetime(interest) {}
        owner.revoke()

        let snapshot = coordinator.prefetchCounters.snapshot
        #expect(snapshot.otherBytes[.visible, default: 0] > 0, "the visible load's bytes, on Wi-Fi")
        #expect(snapshot.speculativeCellularBytes > 0, "the preload's bytes, on cellular")
        #expect(snapshot.cellularBytes[.visible] == nil)
    }

    @Test func theSignedNamespaceReportsItsStoresStatisticsAndReasons() async throws {
        let coordinator = CacheCoordinator(device: device())
        let pipeline = ImagePipeline(fetcher: ScriptedFetcher(), disk: .folder(folder.url), coordinator: coordinator)
        await pipeline.waitUntilDiskIsOpen()
        let signed = try #require(URL(string: "https://cdn.test/private/46.png?X-Amz-Signature=aaa"))
        _ = try await pipeline.image(for: signed)
        #expect(await eventually { pipeline.isOnDisk(signed) })

        coordinator.trim(.viewerChanged)

        let line = try #require(coordinator.usage().lines.first { $0.namespace == ImagePipeline.Namespaces.diskSigned })
        #expect(line.statistics.removals[.viewerChanged] == 1)
        let decoded = try #require(coordinator.usage().lines.first { $0.namespace == ImagePipeline.Namespaces.decoded })
        #expect(decoded.statistics.misses >= 1, "the decoded namespace reports its own lookups")
    }
}

// MARK: - Release paths (#898)

/// Answers every request with a PNG, and records whether each was allowed on
/// a constrained network (Low Data Mode).
private final class ConstrainedRecordingProtocol: URLProtocol {
    static let allowed = Mutex<[String: Bool]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = self.request
        guard let url = current.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        let allowsConstrained = current.allowsConstrainedNetworkAccess
        Self.allowed.withLock { $0[url.lastPathComponent] = allowsConstrained }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: png(width: 8, height: 8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct ImageReleasePathTests {
    private let folder = Folder()

    /// #900's review saw decoded memory grow back after a background trim
    /// (22.5 → 57 MB in 5 s under `-foryou-scroll-demo`): a list kept laying
    /// out cells, and fills landed, while the app was in the background. Now
    /// a decode there is served to its caller and kept nowhere in memory, and
    /// nothing is prefetched, until the foreground.
    @Test func inTheBackgroundNothingGrowsBackInMemory() async throws {
        let coordinator = CacheCoordinator(device: device())
        let fetcher = ScriptedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, coordinator: coordinator)
        let seen = try #require(URL(string: "mock://photo/release-30"))
        _ = try await pipeline.image(for: seen)
        #expect(pipeline.isDecoded(seen))

        coordinator.handle(.didEnterBackground)
        #expect(!pipeline.isDecoded(seen), "the background trim took it")
        let late = try #require(URL(string: "mock://photo/release-31"))
        let image = try await pipeline.image(for: late)
        #expect(pixels(image).width > 0, "the caller still gets its picture")
        #expect(!pipeline.isDecoded(late), "but memory keeps nothing new")
        #expect(pipeline.decodedUsage.bytes == 0)
        let prefetched = try #require(URL(string: "mock://photo/release-32"))
        #expect(pipeline.prefetch(prefetched, window: .display, owner: CacheOwner("feed")) == nil)
        #expect(fetcher.fetchCount(for: prefetched) == 0, "no prefetch in the background")

        coordinator.handle(.willEnterForeground)
        _ = try await pipeline.image(for: late)
        #expect(pipeline.isDecoded(late), "the foreground keeps what it shows again")
    }

    /// The lists' prefetch of the next items (the display window, P1): still
    /// run under `reduced` (Low Power, Low Data Mode: the next item is
    /// allowed), never under `off` (a critical thermal state, offline).
    @Test func theNextItemsPrefetchStopsWhenThePolicyIsOff() async throws {
        let coordinator = CacheCoordinator(device: device(), conditions: CacheConditions(isLowPowerModeEnabled: true))
        let fetcher = ScriptedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, coordinator: coordinator)
        let owner = CacheOwner("feed")
        let next = try #require(URL(string: "mock://photo/release-40"))
        let interest = pipeline.prefetch(next, window: .display, owner: owner)
        #expect(await pipeline.prefetchLanded(next, window: .display), "Low Power keeps the next item")

        coordinator.handle(.thermalState(.critical))
        let ahead = try #require(URL(string: "mock://photo/release-41"))
        #expect(pipeline.prefetch(ahead, window: .display, owner: owner) == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fetcher.fetchCount(for: ahead) == 0, "a critical thermal state prefetches nothing")
        withExtendedLifetime((owner, interest)) {}
    }

    /// Low Data Mode, then Low Power, give P2 no slot: a preload fetches
    /// nothing until both are gone.
    @Test func lowDataModeOrLowPowerFetchesNoSpeculativeImage() async throws {
        let coordinator = CacheCoordinator(device: device(), conditions: CacheConditions(isNetworkConstrained: true))
        let fetcher = ScriptedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url), coordinator: coordinator)
        let owner = CacheOwner("grid")
        let preloaded = try #require(URL(string: "https://cdn.test/photo/release-50.png"))

        let interest = pipeline.prefetch(preloaded, window: .preload, owner: owner)
        coordinator.handle(.lowPowerMode(true))
        coordinator.handle(.network(.wifi, isConstrained: false, isExpensive: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fetcher.fetchCount(for: preloaded) == 0, "P2 waited through Low Data Mode, then Low Power")

        coordinator.handle(.lowPowerMode(false))
        #expect(await pipeline.prefetchLanded(preloaded, window: .preload), "and runs once both are gone")
        withExtendedLifetime((owner, interest)) {}
    }

    /// Every P2 request refuses a constrained network, so a path that turns
    /// constrained mid-fill never spends the viewer's data on a prefetch; a
    /// visible load is allowed.
    @Test func aSpeculativeRequestRefusesConstrainedNetworksAndAVisibleOneDoesNot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConstrainedRecordingProtocol.self]
        let fetcher = URLSessionImageFetcher(session: URLSession(configuration: configuration))
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url), coordinator: CacheCoordinator(device: device()))
        let owner = CacheOwner("grid")
        let preloaded = try #require(URL(string: "https://cdn.test/photo/constrained-p2.png"))
        let shown = try #require(URL(string: "https://cdn.test/photo/constrained-p0.png"))

        let interest = pipeline.prefetch(preloaded, window: .preload, owner: owner)
        #expect(await pipeline.prefetchLanded(preloaded, window: .preload))
        _ = try await pipeline.image(for: shown)

        let allowed = ConstrainedRecordingProtocol.allowed.withLock { $0 }
        #expect(allowed["constrained-p2.png"] == false)
        #expect(allowed["constrained-p0.png"] == true)
        withExtendedLifetime((owner, interest)) {}
    }
}
