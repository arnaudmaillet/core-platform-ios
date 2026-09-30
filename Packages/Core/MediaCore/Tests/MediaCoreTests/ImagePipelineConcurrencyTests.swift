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
/// synchronous API from the main thread (`preloadAutoplayCovers`,
/// `preloadLeadingAutoplayCovers`, every cover gate's `cachedImage`).
private final class PrefetchingView: UIView {
    let pipeline: ImagePipeline

    init(pipeline: ImagePipeline) {
        self.pipeline = pipeline
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func warm(_ urls: [URL]) { pipeline.prefetch(urls) }
    func drop(_ urls: [URL]) { pipeline.cancelPrefetch(urls) }
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
        let pipeline = ImagePipeline(fetcher: InstantFetcher(), countLimit: 100_000)
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
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, !kept.allSatisfy(view.isCached) {
            for _ in 0..<2_000 { view.drop([stray]) }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(kept.allSatisfy(view.isCached))
        while ContinuousClock.now < deadline, pipeline.pendingPrefetchCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pipeline.pendingPrefetchCount == 0)
    }

    /// A scroll that passes a tile and comes back cancels its prefetch and asks
    /// again while the first fetch is still out: the second ask rides the same
    /// fetch, and both leave the table empty once it lands.
    @Test func aPrefetchCancelledAndAskedAgainSharesOneFetch() async throws {
        let fetcher = GatedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let url = URL(string: "mock://race/successor")!

        pipeline.prefetch([url])
        pipeline.cancelPrefetch([url])
        pipeline.prefetch([url])
        #expect(pipeline.pendingPrefetchCount == 1)

        await fetcher.open()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, pipeline.pendingPrefetchCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pipeline.pendingPrefetchCount == 0)
        #expect(pipeline.cachedImage(for: url) != nil)
        #expect(await fetcher.fetchCount == 1)
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
