import Foundation
import Testing
import UIKit
@testable import MediaCore

/// Hands back the same tiny PNG after a millisecond, so prefetches complete —
/// and clear their own bookkeeping — while the main thread is still at work
/// on the same table.
private struct InstantFetcher: ImageFetching {
    static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
        UIColor.gray.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    func fetchImageData(for url: URL) async throws -> Data {
        try? await Task.sleep(for: .milliseconds(1))
        return Self.png
    }
}

/// The app's callers, reproduced in their exact shape: a UIKit subclass —
/// main-actor by INFERENCE, like `ForYouGridPage` — calling the pipeline's
/// synchronous API from the main thread (a list's `ImageLookahead`, #970,
/// and every cover gate's `cachedImage`).
private final class PrefetchingView: UIView {
    let pipeline: ImagePipeline
    let lookahead: ImageLookahead
    /// The list's display window: what it has asked for and not dropped.
    private var wanted: [ImageRequest] = []

    init(pipeline: ImagePipeline) {
        self.pipeline = pipeline
        lookahead = ImageLookahead(pipeline: pipeline, name: "race")
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func warm(_ urls: [URL]) {
        let known = Set(wanted)
        wanted += urls.map { ImageRequest(url: $0) }.filter { !known.contains($0) }
        lookahead.update(display: wanted, preload: [])
    }

    func drop(_ urls: [URL]) {
        let dropped = Set(urls.map { ImageRequest(url: $0) })
        wanted.removeAll { dropped.contains($0) }
        lookahead.update(display: wanted, preload: [])
    }

    func isCached(_ url: URL) -> Bool { pipeline.cachedImage(for: url) != nil }
}

/// The pipeline's synchronous surface under contention.
///
/// ⚠️ Run this suite with the Thread Sanitizer as well as without: the crash it
/// guards (`Dictionary._Variant.lookup` → `doesNotRecognizeSelector` inside
/// `prefetch`, three app crashes on 2026-09-30) was a DATA RACE, which a plain
/// run only catches when it happens to corrupt the table. While the pipeline was
/// an `actor`, the calls above compiled with a mere warning (the caller's
/// isolation is inferred from UIKit) and ran on the main thread WITHOUT
/// entering the actor, while the actor's own prefetch tasks removed their
/// entries from the same dictionary on the cooperative pool.
@MainActor
struct ImagePipelineConcurrencyTests {
    @Test func mainThreadPrefetchAndCancelRaceNothingAndEveryKeptPrefetchLands() async throws {
        let pipeline = ImagePipeline(fetcher: InstantFetcher(), memoryLimit: 1 << 30)
        let view = PrefetchingView(pipeline: pipeline)

        var kept: [URL] = []
        for round in 0..<400 {
            let urls = (0..<8).map { URL(string: "mock://race/\(round)/\($0)")! }
            view.warm(urls)
            // Re-asks for the previous round, some of it finished, some not —
            // the lookup the crash reports died in.
            if round > 0 {
                view.warm((0..<8).map { URL(string: "mock://race/\(round - 1)/\($0)")! })
            }
            view.drop(Array(urls.prefix(2)))
            kept += urls.dropFirst(2)
        }

        // Keeps the main thread writing the prefetch table while the pool is
        // still retiring entries from it — without starting any new task, which
        // would hand the sanitizer a happens-before edge and hide the race.
        let stray = URL(string: "mock://race/stray")!
        let landed = await settle {
            for _ in 0..<2_000 { view.drop([stray]) }
            return kept.allSatisfy(view.isCached)
        }
        #expect(landed, "every kept prefetch lands")
        #expect(await settle { view.lookahead.activeInterestCount == 0 }, "and none is left pending")
    }

    /// A look budget, not a wall-clock deadline: every wait here is positive
    /// and stops as soon as its condition holds, so the budget only matters on
    /// a starved runner, where each look stretches (#966, #980). It answers,
    /// so a timeout fails at the wait. The 2,400 kept decodes ran past the
    /// old 20-second deadline on a starved CI lane.
    private static let looks = 12_000

    private func settle(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<Self.looks {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// A scroll that passes a tile and comes back cancels its prefetch and asks
    /// again while the first fetch is still out. A visible load waits on the
    /// same image, so the cancel leaves the fetch running for it (#894: a
    /// shared fill is cancelled only when nobody wants it), the second ask
    /// rides that fetch, and both leave the table empty once it lands.
    @Test func aPrefetchCancelledAndAskedAgainSharesOneFetch() async throws {
        let fetcher = GatedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let view = PrefetchingView(pipeline: pipeline)
        let url = URL(string: "mock://race/successor")!

        // The visible load first, so it is surely waiting before the cancel.
        let visible = Task { try await pipeline.image(for: url) }
        #expect(await settle { await fetcher.fetchCount == 1 })
        view.warm([url])
        view.drop([url])
        view.warm([url])
        #expect(view.lookahead.activeInterestCount == 1)

        await fetcher.open()
        #expect(await settle { view.lookahead.activeInterestCount == 0 })
        #expect(pipeline.cachedImage(for: url) != nil)
        #expect(await fetcher.fetchCount == 1)
        _ = try await visible.value
    }

    /// A prefetch nobody else waits for is cancelled with it (#894), and a
    /// later ask starts again.
    @Test func aCancelledPrefetchNobodyElseWantsStopsItsFetch() async throws {
        let fetcher = GatedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let view = PrefetchingView(pipeline: pipeline)
        let url = URL(string: "mock://race/abandoned")!

        view.warm([url])
        #expect(await settle { await fetcher.fetchCount == 1 })
        view.drop([url])

        #expect(view.lookahead.activeInterestCount == 0)
        #expect(pipeline.inFlightCount == 0)
        await fetcher.open()
    }
}

/// Holds every fetch until `open()`, so a test can arrange what is in flight.
private actor GatedFetcher: ImageFetching {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var fetchCount = 0

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func fetchImageData(for url: URL) async throws -> Data {
        fetchCount += 1
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return InstantFetcher.png
    }
}
