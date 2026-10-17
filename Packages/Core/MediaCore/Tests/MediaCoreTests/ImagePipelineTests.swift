import Foundation
import Testing
import UIKit
@testable import MediaCore

/// Counts fetches so coalescing/caching are observable.
private final class CountingFetcher: ImageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var fetchCount: Int { lock.withLock { count } }

    func fetchImageData(for url: URL) async throws -> Data {
        lock.withLock { count += 1 }
        try? await Task.sleep(nanoseconds: 20_000_000) // let racers pile up
        return try await PlaceholderImageFetcher().fetchImageData(for: url)
    }
}

/// Counts fetches and holds every answer until `release()` (#1290): a
/// coalescing test can then prove that callers JOINED the fill in flight,
/// instead of hoping a 20 ms sleep outlasted a starved runner's scheduling.
private final class GatedFetcher: ImageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var fetchCount: Int { lock.withLock { count } }

    func fetchImageData(for url: URL) async throws -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = lock.withLock {
                count += 1
                if !released { waiting.append(continuation) }
                return released
            }
            if open { continuation.resume() }
        }
        return try await PlaceholderImageFetcher().fetchImageData(for: url)
    }

    func release() {
        let held = lock.withLock {
            released = true
            defer { waiting = [] }
            return waiting
        }
        held.forEach { $0.resume() }
    }
}

struct ImagePipelineTests {
    /// ⚠️ THE FETCH IS HELD UNTIL ALL EIGHT HAVE JOINED (#1290). It used to
    /// answer after a 20 ms sleep: on a starved runner the first fill could
    /// finish and leave the in-flight table before a late caller started,
    /// and that caller's own fetch failed the count — twice in two days on
    /// PRs that never touched the pipeline. Now the answer waits on the
    /// pipeline's own count of joined callers, however long they take.
    @Test func concurrentRequestsForSameURLCoalesceIntoOneFetch() async throws {
        let fetcher = GatedFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let url = URL(string: "mock://media/1?w=64&h=64")!
        let callers = 8

        let images = try await withThrowingTaskGroup(of: UIImage.self) { group in
            for _ in 0..<callers {
                group.addTask { try await pipeline.image(for: url) }
            }
            // Every caller in the ONE fill before it may answer. A look
            // budget on a count, not a sleep: without coalescing the count
            // never reaches eight and the test fails here. Released either
            // way, so a failure never leaves the group waiting.
            let joined = await Self.look(until: { pipeline.decodeInterestCount(for: url) >= callers })
            fetcher.release()
            #expect(joined, "the callers never joined one fill")
            return try await group.reduce(into: [UIImage]()) { $0.append($1) }
        }

        #expect(images.count == callers)
        #expect(fetcher.fetchCount == 1)
    }

    /// Looks for `condition` up to `looks` times, 10 ms apart.
    ///
    /// ⚠️ A LOOK BUDGET, NOT A DEADLINE: it counts its looks instead of
    /// reading the clock. On a starved runner the process is suspended while
    /// the wall clock runs on, and a deadline can pass with almost no looks
    /// taken — how #967, #1046 and #1059 flaked.
    private static func look(looks: Int = 6_000, until condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @Test func secondRequestIsServedFromCache() async throws {
        let fetcher = CountingFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let url = URL(string: "mock://media/2?w=64&h=64")!

        _ = try await pipeline.image(for: url)
        _ = try await pipeline.image(for: url)

        #expect(fetcher.fetchCount == 1)
        #expect(pipeline.cachedImage(for: url) != nil)
    }

    @Test func decodeDownsamplesToMaxPixelSize() async throws {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher(), maxPixelSize: 100)
        let url = URL(string: "mock://media/3?w=1600&h=1200")!

        let image = try await pipeline.image(for: url)

        #expect(max(image.size.width, image.size.height) <= 100)
    }

    @Test func placeholderFetcherIsDeterministicPerURL() async throws {
        let fetcher = PlaceholderImageFetcher()
        let first = try await fetcher.fetchImageData(for: URL(string: "mock://avatar/7?w=32&h=32")!)
        let second = try await fetcher.fetchImageData(for: URL(string: "mock://avatar/7?w=32&h=32")!)
        #expect(first == second)
    }
}
