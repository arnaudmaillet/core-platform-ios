import CacheKit
import Foundation
import Synchronization
import Testing
import UIKit
@testable import MediaCore

// MARK: - Support

/// Counts fetches and holds every one until `open()`; serves a small PNG.
private final class HeldFetcher: ImageFetching {
    private struct FetchWaiter {
        let url: String?
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var fetches: [String: Int] = [:]
        var isHeld: Bool
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

    private let state: Mutex<State>

    init(held: Bool = true) {
        state = Mutex(State(isHeld: held))
    }

    var fetchCount: Int { state.withLock { $0.fetches.values.reduce(0, +) } }

    func fetchCount(for url: URL) -> Int { state.withLock { $0.fetches[url.absoluteString] ?? 0 } }

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
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}

/// A private folder, deleted with the suite instance.
private final class Folder: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ListLookaheadTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A look budget, not a deadline: stops as soon as `condition` holds.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<6_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func image(_ index: Int, list: String = "post") -> ImageRequest {
    ImageRequest(url: URL(string: "https://cdn.test/\(list)/\(index).png")!)
}

private func images(_ indices: some Sequence<Int>) -> Set<ImageRequest> {
    Set(indices.map { image($0) })
}

/// A list of 100 items, 100 pt long each, along `axis`, in a 400 × 800
/// viewport; item `i` shows `image(i)`.
@MainActor
private final class StubList: NSObject, UICollectionViewDataSource {
    let collectionView: UICollectionView
    var count = 100

    init(axis: NSLayoutConstraint.Axis) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = axis == .horizontal ? .horizontal : .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.itemSize = axis == .horizontal ? CGSize(width: 100, height: 800) : CGSize(width: 400, height: 100)
        collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), collectionViewLayout: layout)
        super.init()
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        collectionView.dataSource = self
        collectionView.layoutIfNeeded()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
    }

    func scroll(to offset: CGFloat, axis: NSLayoutConstraint.Axis) {
        collectionView.contentOffset = axis == .horizontal ? CGPoint(x: offset, y: 0) : CGPoint(x: 0, y: offset)
    }
}

/// A clock the test moves by hand.
private final class ManualTime: @unchecked Sendable {
    var now: CFTimeInterval = 100
}

@MainActor
private func lookahead(
    _ list: StubList, pipeline: ImagePipeline, kind: LookaheadListKind, name: String = "grid",
    time: ManualTime = ManualTime(), images: @escaping (Int) -> [ImageRequest] = { [image($0)] }
) -> ScrollLookahead {
    let lookahead = ScrollLookahead(pipeline: pipeline, name: name, kind: kind, now: { time.now }) { path in
        images(path.item)
    }
    lookahead.attach(to: list.collectionView)
    lookahead.setOnScreen(true)
    return lookahead
}

// MARK: - The shared, deduplicated cache (#970)

@MainActor
struct SharedLookaheadTests {
    private let folder = Folder()

    @Test func twoListsShareOneFetchAtTheHighestOwnerPriority() async throws {
        let fetcher = HeldFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url))
        let grid = ImageLookahead(pipeline: pipeline, name: "grid")
        let feed = ImageLookahead(pipeline: pipeline, name: "feed")
        let shared = image(1, list: "shared")

        // The vertical feed wants it decoded (P1), the grid on disk (P2). The
        // feed first: its decode reaching the download is awaited at the
        // fetch, never polled under a budget (#1049); the grid's P2 interest
        // then joins the running download synchronously.
        feed.update(display: [shared], preload: [])
        await fetcher.fetchesBegan()
        #expect(pipeline.downloadPriority(for: shared.url) == .next)
        grid.update(display: [], preload: [shared])

        #expect(pipeline.downloadPriority(for: shared.url) == .next,
                "the one download runs at the highest priority among its owners")
        feed.revoke()
        #expect(await eventually { pipeline.downloadPriority(for: shared.url) == .speculative },
                "back to the grid's once the feed left")
        #expect(pipeline.inFlightCount == 1, "still wanted by the grid: not cancelled")
        grid.revoke()
        #expect(pipeline.inFlightCount == 0, "cancelled once no owner is left")
        fetcher.open()
        #expect(fetcher.fetchCount == 1, "fetched once for both lists")
    }

    @Test func aListLeavingTheScreenCancelsOnlyWhatItAloneWanted() async throws {
        let fetcher = HeldFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url))
        let gridList = StubList(axis: .vertical)
        let cardList = StubList(axis: .vertical)
        // Items 0...3 are the same posts in both lists; the rest are each its own.
        let grid = lookahead(gridList, pipeline: pipeline, kind: .grid, name: "grid") {
            [$0 < 4 ? image($0, list: "shared") : image($0, list: "grid")]
        }
        let cards = lookahead(cardList, pipeline: pipeline, kind: .card, name: "cards") {
            [$0 < 4 ? image($0, list: "shared") : image($0, list: "cards")]
        }
        grid.scrollViewDidScroll()
        cards.scrollViewDidScroll()
        let mine = image(5, list: "grid")
        let shared = image(1, list: "shared")
        await fetcher.fetchesBegan(of: mine.url)
        await fetcher.fetchesBegan(of: shared.url)

        grid.setOnScreen(false)

        #expect(!grid.isOnScreen && grid.activeInterestCount == 0)
        #expect(await eventually { pipeline.downloadPriority(for: mine.url) == nil }, "only the grid wanted it: cancelled")
        #expect(pipeline.downloadPriority(for: shared.url) != nil, "the card list still wants it")
        fetcher.open()
        #expect(await pipeline.prefetchLanded(shared.url, window: .display))
        #expect(fetcher.fetchCount(for: shared.url) == 1)
        cards.setOnScreen(false)
    }
}

// MARK: - Windows per kind (#970)

@MainActor
struct ListLookaheadWindowTests {
    private let folder = Folder()

    @Test func aGridDecodesOneScreenAheadAndPreloadsTwoAndAHalf() {
        let pipeline = ImagePipeline(fetcher: HeldFetcher(), disk: .folder(folder.url))
        let list = StubList(axis: .vertical)
        let grid = lookahead(list, pipeline: pipeline, kind: .grid)
        list.scroll(to: 1_600, axis: .vertical)

        grid.scrollViewDidScroll()

        // Visible 1600..2400; display 1.0 ahead / 0.5 behind = 1200..3200;
        // preload 2.5 / 1.5 = 400..4400.
        #expect(Set(grid.planned.display) == images(12..<32))
        #expect(Set(grid.planned.preload) == images(4..<12).union(images(32..<44)))
        #expect(grid.window(of: image(20)) == .display)
        #expect(grid.window(of: image(40)) == .preload)
        #expect(grid.window(of: image(50)) == nil)
        grid.setOnScreen(false)
    }

    @Test func theWindowsFaceTheScrollDirection() {
        let time = ManualTime()
        let pipeline = ImagePipeline(fetcher: HeldFetcher(), disk: .folder(folder.url))
        let list = StubList(axis: .vertical)
        let cards = lookahead(list, pipeline: pipeline, kind: .card, time: time)
        list.scroll(to: 3_000, axis: .vertical)
        cards.scrollViewDidScroll()
        time.now += 0.5
        list.scroll(to: 2_000, axis: .vertical)

        cards.scrollViewDidScroll()

        // Up: visible 2000..2800, a screen ahead is ABOVE (1200), half behind below (3200).
        #expect(Set(cards.planned.display) == images(12..<32))
        // 2.5 screens up reaches the top; 1.5 screens down stops at 4000.
        #expect(Set(cards.planned.preload) == images(0..<12).union(images(32..<40)))
        cards.setOnScreen(false)
    }

    @Test func aRailPlansAlongItsHorizontalAxis() {
        let pipeline = ImagePipeline(fetcher: HeldFetcher(), disk: .folder(folder.url))
        let list = StubList(axis: .horizontal)
        let rail = lookahead(list, pipeline: pipeline, kind: .rail)

        rail.scrollViewDidScroll()

        // Visible 0..400 wide; display to 800, preload to 1400.
        #expect(Set(rail.planned.display) == images(0..<8))
        #expect(Set(rail.planned.preload) == images(8..<14))
        rail.setInParentWindow(false)
        #expect(rail.planned.display.isEmpty && rail.planned.preload.isEmpty,
                "a rail outside its parent's display window plans nothing")
        rail.setOnScreen(false)
    }

    @Test func aHiddenListFallsToTheMinimumWindowsAndToNothingUnderMemoryPressure() async {
        let coordinator = CacheCoordinator(device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { nil }))
        let pipeline = ImagePipeline(fetcher: HeldFetcher(), disk: .folder(folder.url), coordinator: coordinator)
        let list = StubList(axis: .vertical)
        let grid = lookahead(list, pipeline: pipeline, kind: .grid)
        list.scroll(to: 1_600, axis: .vertical)
        grid.scrollViewDidScroll()

        grid.setHidden(true)

        // Visible 1600..2400; hidden display 0.25 / 0.25 = 1400..2600;
        // hidden preload 0.5 / 0.25 = 1400..2800.
        #expect(grid.windows.display == .hiddenDisplay && grid.windows.preload == .hiddenPreload)
        #expect(Set(grid.planned.display) == images(14..<26))
        #expect(Set(grid.planned.preload) == images(26..<28))
        #expect(grid.window(of: image(20)) == .preload, "a hidden list does not decode")

        coordinator.handle(.memoryWarning)
        #expect(await eventually { grid.planned.display.isEmpty && grid.planned.preload.isEmpty })
        #expect(grid.activeInterestCount == 0)

        grid.setHidden(false)
        #expect(Set(grid.planned.display) == images(12..<32), "shown again: full windows")
        grid.setOnScreen(false)
    }

    /// ⚠️ THE POLICY'S `off` IS P0 ONLY (#898): in the background (or
    /// offline, or at a critical thermal state) no list plans anything and
    /// the pipeline refuses every prefetch, the vertical feed's included.
    @Test func inTheBackgroundNothingIsPrefetched() async {
        let coordinator = CacheCoordinator(device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { nil }))
        let fetcher = HeldFetcher(held: false)
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url), coordinator: coordinator)
        coordinator.updateConditions { $0.isInBackground = true }
        let list = StubList(axis: .vertical)
        let grid = lookahead(list, pipeline: pipeline, kind: .grid)

        grid.scrollViewDidScroll()

        #expect(grid.planned.display.isEmpty && grid.planned.preload.isEmpty)
        let feed = CacheOwner("snap-feed")
        #expect(pipeline.prefetch(image(1).url, window: .display, owner: feed) == nil)
        #expect(pipeline.prefetch(image(2).url, window: .preload, owner: feed) == nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fetcher.fetchCount == 0)

        coordinator.updateConditions { $0.isInBackground = false }
        #expect(await eventually { !grid.planned.display.isEmpty }, "back in the foreground: planned afresh")
        await fetcher.fetchesBegan()
        grid.setOnScreen(false)
    }

    @Test func aFlingDownloadsTheDisplayWindowWithoutDecodingUntilItSlows() {
        let time = ManualTime()
        let pipeline = ImagePipeline(fetcher: HeldFetcher(), disk: .folder(folder.url))
        let list = StubList(axis: .vertical)
        let grid = lookahead(list, pipeline: pipeline, kind: .grid, time: time)
        grid.scrollViewDidScroll()
        time.now += 0.016
        // 800 pt in one frame: 50 screens a second.
        list.scroll(to: 800, axis: .vertical)

        grid.scrollViewDidScroll()

        #expect(grid.isFlinging)
        #expect(grid.planned.display.contains(image(10)))
        #expect(grid.window(of: image(10)) == .preload, "no decode while flinging, the bytes still come")

        grid.scrollViewDidEndScrolling()

        #expect(!grid.isFlinging)
        #expect(grid.window(of: image(10)) == .display, "decoded once the scroll slows")
        grid.setOnScreen(false)
    }

    @Test func aNewStayIsANewOwner() async {
        let fetcher = HeldFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(folder.url))
        let list = StubList(axis: .vertical)
        let grid = lookahead(list, pipeline: pipeline, kind: .grid)
        grid.scrollViewDidScroll()
        #expect(await eventually { grid.activeInterestCount > 0 })

        grid.setOnScreen(false)
        #expect(grid.activeInterestCount == 0)
        #expect(await eventually { pipeline.inFlightCount == 0 }, "the stay's owner is revoked")
        grid.setOnScreen(true)
        grid.scrollViewDidScroll()

        #expect(await eventually { grid.activeInterestCount > 0 }, "back on screen: a fresh owner plans again")
        grid.setOnScreen(false)
        fetcher.open()
    }
}

// MARK: - The next page (#970)

@MainActor
struct LookaheadPagingTests {
    @Test func theVerticalFeedAsksAtFivePostsLeft() {
        #expect(!LookaheadPaging.wantsNextPage(index: 4, count: 10))
        #expect(LookaheadPaging.wantsNextPage(index: 5, count: 10), "5 left: asks")
        #expect(LookaheadPaging.wantsNextPage(index: 9, count: 10))
        #expect(!LookaheadPaging.wantsNextPage(index: 0, count: 0))
    }

    @Test func aGridAsksTwoScreensFromItsEndAndThreeOnAFling() {
        #expect(LookaheadPaging.wantsNextPage(remaining: 1_500, viewportLength: 800, isFlinging: false))
        #expect(!LookaheadPaging.wantsNextPage(remaining: 1_700, viewportLength: 800, isFlinging: false))
        #expect(LookaheadPaging.wantsNextPage(remaining: 2_300, viewportLength: 800, isFlinging: true))
        #expect(!LookaheadPaging.wantsNextPage(remaining: 2_500, viewportLength: 800, isFlinging: true))
        #expect(LookaheadPaging.wantsNextPage(remaining: 700, viewportLength: 0, isFlinging: false),
                "before the first layout, a floor of 800 pt")
    }

    @Test func aListReadsItsOwnDistanceToTheEnd() {
        let time = ManualTime()
        let pipeline = ImagePipeline(fetcher: HeldFetcher())
        let list = StubList(axis: .vertical)
        let grid = lookahead(list, pipeline: pipeline, kind: .grid, time: time)
        // 100 items of 100 pt: content is 10 000 pt long.
        list.scroll(to: 7_000, axis: .vertical)
        grid.scrollViewDidScroll()
        #expect(!grid.wantsNextPage, "2200 pt left: more than two screens")

        time.now += 1
        list.scroll(to: 7_700, axis: .vertical)
        grid.scrollViewDidScroll()
        #expect(grid.wantsNextPage, "1500 pt left")

        time.now += 1
        list.scroll(to: 6_500, axis: .vertical)
        grid.scrollViewDidScroll()
        time.now += 0.016
        list.scroll(to: 7_000, axis: .vertical)
        grid.scrollViewDidScroll()
        #expect(grid.isFlinging)
        #expect(grid.wantsNextPage, "2200 pt left, but a fling asks three screens ahead")
        grid.setOnScreen(false)
    }
}

// MARK: - The vertical feed (#970)

struct VerticalLookaheadPlanTests {
    /// Page `i` shows `image(i)`; page 4 is a text post (no picture).
    private let pages: [[ImageRequest]] = (0..<8).map { $0 == 4 ? [] : [image($0)] }

    @Test func plusOneAndTwoAreDecodedAndPlusThreeGoesToDisk() {
        let plan = VerticalLookaheadPlan.images(around: 0, pages: pages, depth: 3)
        #expect(Set(plan.display) == images([0, 1, 2]), "the page, +1 and +2 decoded")
        #expect(plan.preload == [image(3)], "+3 to disk only")
        let behind = VerticalLookaheadPlan.images(around: 2, pages: pages, depth: 3)
        #expect(Set(behind.display) == images([1, 2, 3]), "−1 kept; +2 is a text post: data only")
        #expect(behind.preload == [image(5)])
    }

    @Test func depthFollowsThePolicy() {
        #expect(VerticalLookaheadPlan.images(around: 4, pages: pages, depth: 3).preload == [image(7)])
        let cellular = VerticalLookaheadPlan.images(around: 0, pages: pages, depth: 2)
        #expect(Set(cellular.display) == images([0, 1, 2]) && cellular.preload.isEmpty, "cellular: +1 and +2 decoded, nothing on disk")
        let reduced = VerticalLookaheadPlan.images(around: 0, pages: pages, depth: 1)
        #expect(Set(reduced.display) == images([0, 1]) && reduced.preload.isEmpty, "Low Data / Low Power: +1 only")
        let off = VerticalLookaheadPlan.images(around: 2, pages: pages, depth: 0)
        #expect(off.display.isEmpty && off.preload.isEmpty, "off (background, offline): nothing, the page is its cell's own load")
        let outside = VerticalLookaheadPlan.images(around: 9, pages: pages, depth: 3)
        #expect(outside.display.isEmpty && outside.preload.isEmpty, "no page there: nothing")
    }
}
