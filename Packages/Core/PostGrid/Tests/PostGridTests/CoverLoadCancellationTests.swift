import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A cell's cover load outlives the post it was started for: a row recycled
/// mid-load, a reconfigure with a newer model. These pin the two ways that
/// went wrong (#777): a cancelled carousel page that never loaded again (#779),
/// and an old cover landing over the right one after a reconfigure (#781).
///
/// The fetcher holds every load until the test lets it go, so what is in
/// flight is arranged, never raced against a clock.
@MainActor
struct CoverLoadCancellationTests {
    private static func photo(_ id: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "mock://\(id)"), aspectRatio: 1,
            caption: "", publishedAtMS: 0
        )
    }

    // MARK: - #779

    /// A page whose load was cancelled (the row recycled, the card hidden) is
    /// no longer counted as loaded, and the next configure with the SAME pages
    /// asks for it again — instead of returning early over an empty fill.
    @Test func aCarouselPageCancelledMidLoadLoadsOnTheNextConfigureOfTheSamePost() async throws {
        let fetcher = GatedCoverFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let url = try #require(URL(string: "mock://page-a"))
        let pages = [GalleryPost.MediaPage(thumbnailURL: url, aspectRatio: 1)]
        let carousel = MediaCarouselView(style: .page, frame: CGRect(x: 0, y: 0, width: 300, height: 300))

        carousel.configure(with: pages, imagePipeline: pipeline)
        #expect(carousel.loadedPages == [0])

        carousel.cancelPendingWork()
        #expect(carousel.loadedPages.isEmpty)

        // The picture arrives after all — into the cache, not into the
        // cancelled page.
        await fetcher.releaseAll()
        _ = try await pipeline.image(for: url)
        #expect(carousel.cover(onPage: 0) == nil)

        carousel.configure(with: pages, imagePipeline: pipeline)
        #expect(carousel.loadedPages == [0])
        #expect(carousel.cover(onPage: 0) === pipeline.cachedImage(for: url))
    }

    /// A page whose fetch FAILED is not counted as loaded either: the next
    /// window that shows it asks again, instead of leaving an empty fill.
    @Test func aCarouselPageWhoseFetchFailedIsAskedForAgain() async throws {
        let fetcher = FailOnceFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let url = try #require(URL(string: "mock://page-failing"))
        let pages = [GalleryPost.MediaPage(thumbnailURL: url, aspectRatio: 1)]
        let carousel = MediaCarouselView(style: .page, frame: CGRect(x: 0, y: 0, width: 300, height: 300))

        carousel.configure(with: pages, imagePipeline: pipeline)
        #expect(carousel.loadedPages == [0])
        // Join the carousel's own fetch (held, so it is still in flight), let
        // it fail, and give the carousel's completion its main-actor turn.
        let failure = Task { await fetcher.fail() }
        #expect(await (try? pipeline.image(for: url)) == nil)
        await failure.value
        for _ in 0..<100 where carousel.loadedPages.contains(0) { await Task.yield() }
        #expect(carousel.loadedPages.isEmpty)
        #expect(carousel.cover(onPage: 0) == nil)

        // The second fetch succeeds, and the next configure asks again.
        _ = try await pipeline.image(for: url)
        carousel.configure(with: pages, imagePipeline: pipeline)
        #expect(carousel.cover(onPage: 0) === pipeline.cachedImage(for: url))
        #expect(await fetcher.fetchCount == 2)
    }

    // MARK: - #781

    /// A second configure cancels the first cover load, and only the latest
    /// post's cover lands on the tile.
    @Test(.timeLimit(.minutes(1)))
    func aTileReconfiguredMidLoadCancelsTheFirstCoverAndShowsOnlyTheLatest() async throws {
        let fetcher = GatedCoverFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let first = Self.photo("tile-a"), second = Self.photo("tile-b")
        let firstURL = try #require(first.thumbnailURL), secondURL = try #require(second.thumbnailURL)
        let cell = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 120))

        cell.configure(with: first, imagePipeline: pipeline)
        let firstLoad = try #require(cell.loadTask)
        cell.configure(with: second, imagePipeline: pipeline)

        #expect(firstLoad.isCancelled)
        #expect(cell.loadTask != nil)

        // The old cover lands first, then the right one.
        let landings = CoverLandings()
        cell.onCoverLoaded = { landings.land() }
        await fetcher.release(firstURL)
        _ = try await pipeline.image(for: firstURL)
        await landings.next { await fetcher.release(secondURL) }

        #expect(landings.count == 1)
        #expect(cell.renderedCover === pipeline.cachedImage(for: secondURL))
    }

    /// The list row's single-media cover follows the same rule.
    @Test func aListRowReconfiguredMidLoadCancelsTheFirstCover() throws {
        let pipeline = ImagePipeline(fetcher: GatedCoverFetcher())
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 600))

        cell.configure(with: Self.photo("row-a"), imagePipeline: pipeline)
        let firstLoad = try #require(cell.loadTask)
        cell.configure(with: Self.photo("row-b"), imagePipeline: pipeline)

        #expect(firstLoad.isCancelled)
        #expect(cell.loadTask != nil)
    }
}

/// Counts covers landing on a cell, and lets a test wait for the next one.
@MainActor
private final class CoverLandings {
    private(set) var count = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func land() {
        count += 1
        waiter?.resume()
        waiter = nil
    }

    /// Runs `trigger`, then returns once the next cover has landed.
    func next(_ trigger: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            Task { await trigger() }
        }
    }
}

/// Holds each URL's fetch until the test releases it.
private actor GatedCoverFetcher: ImageFetching {
    private var released: Set<URL> = []
    private var releasedAll = false
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func release(_ url: URL) {
        released.insert(url)
        waiters.removeValue(forKey: url)?.forEach { $0.resume() }
    }

    func releaseAll() {
        releasedAll = true
        let pending = waiters
        waiters = [:]
        pending.values.joined().forEach { $0.resume() }
    }

    func fetchImageData(for url: URL) async throws -> Data {
        if !releasedAll, !released.contains(url) {
            await withCheckedContinuation { waiters[url, default: []].append($0) }
        }
        return Self.onePixelPNG
    }

    /// The smallest thing `CGImageSourceCreateThumbnailAtIndex` will decode.
    static let onePixelPNG = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
}

/// Holds its first fetch until `fail()`, fails it, then serves a picture.
private actor FailOnceFetcher: ImageFetching {
    private(set) var fetchCount = 0
    private var failed = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fail() {
        failed = true
        waiter?.resume()
        waiter = nil
    }

    func fetchImageData(for url: URL) async throws -> Data {
        fetchCount += 1
        guard fetchCount == 1 else { return GatedCoverFetcher.onePixelPNG }
        if !failed { await withCheckedContinuation { waiter = $0 } }
        throw URLError(.notConnectedToInternet)
    }
}
