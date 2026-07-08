import Foundation
import ImageIO
import UIKit

/// The app-wide image pipeline: memory cache → request coalescing →
/// fetch → downsampled decode, all off the main thread.
///
/// Decoding uses `CGImageSourceCreateThumbnailAtIndex`, so a 12MP original
/// costs a cell-sized bitmap, not a 40MB decode. Feed prefetching calls
/// `prefetch(_:)` from `UICollectionViewDataSourcePrefetching`.
public actor ImagePipeline {
    public static let defaultMaxPixelSize = 1200

    private let fetcher: any ImageFetching
    private let maxPixelSize: Int
    private let cache = NSCache<NSURL, UIImage>()
    private var inflight: [URL: Task<UIImage, Error>] = [:]
    private var prefetches: [URL: Task<Void, Never>] = [:]

    public init(fetcher: any ImageFetching, maxPixelSize: Int = ImagePipeline.defaultMaxPixelSize, countLimit: Int = 300) {
        self.fetcher = fetcher
        self.maxPixelSize = maxPixelSize
        cache.countLimit = countLimit
    }

    /// Cached-or-loaded image for `url`. Concurrent callers for the same URL
    /// share one fetch+decode.
    public func image(for url: URL) async throws -> UIImage {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        if let task = inflight[url] {
            return try await task.value
        }

        let fetcher = fetcher
        let maxPixelSize = maxPixelSize
        let task = Task<UIImage, Error> {
            let data = try await fetcher.fetchImageData(for: url)
            return try Self.decodeDownsampled(data, maxPixelSize: maxPixelSize)
        }
        inflight[url] = task
        defer { inflight[url] = nil }

        do {
            let image = try await task.value
            cache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            throw error
        }
    }

    /// Synchronously returns the cached image if present — for cell
    /// configuration paths that must not suspend.
    public func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Seeds the cache with an already-decoded image under `url`. Used for
    /// optimistic rendering: a just-picked local image renders instantly
    /// under its freshly-minted CDN URL, before any network fetch.
    public func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    // MARK: - Prefetching

    public func prefetch(_ urls: [URL]) {
        for url in urls where prefetches[url] == nil && cache.object(forKey: url as NSURL) == nil {
            prefetches[url] = Task { [weak self] in
                _ = try? await self?.image(for: url)
                await self?.clearPrefetch(url)
            }
        }
    }

    public func cancelPrefetch(_ urls: [URL]) {
        for url in urls {
            prefetches[url]?.cancel()
            prefetches[url] = nil
        }
    }

    private func clearPrefetch(_ url: URL) {
        prefetches[url] = nil
    }

    // MARK: - Decoding

    private static func decodeDownsampled(_ data: Data, maxPixelSize: Int) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: cgImage)
    }
}
