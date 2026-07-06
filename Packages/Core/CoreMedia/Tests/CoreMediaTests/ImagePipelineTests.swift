import Foundation
import Testing
import UIKit
@testable import CoreMedia

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

struct ImagePipelineTests {
    @Test func concurrentRequestsForSameURLCoalesceIntoOneFetch() async throws {
        let fetcher = CountingFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let url = URL(string: "mock://media/1?w=64&h=64")!

        let images = try await withThrowingTaskGroup(of: UIImage.self) { group in
            for _ in 0..<8 {
                group.addTask { try await pipeline.image(for: url) }
            }
            return try await group.reduce(into: [UIImage]()) { $0.append($1) }
        }

        #expect(images.count == 8)
        #expect(fetcher.fetchCount == 1)
    }

    @Test func secondRequestIsServedFromCache() async throws {
        let fetcher = CountingFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let url = URL(string: "mock://media/2?w=64&h=64")!

        _ = try await pipeline.image(for: url)
        _ = try await pipeline.image(for: url)

        #expect(fetcher.fetchCount == 1)
        #expect(await pipeline.cachedImage(for: url) != nil)
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
