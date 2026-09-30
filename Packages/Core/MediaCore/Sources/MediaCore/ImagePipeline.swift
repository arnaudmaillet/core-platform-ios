import Foundation
import ImageIO
import Synchronization
import UIKit

/// The app-wide image pipeline: memory cache → request coalescing →
/// fetch → downsampled decode, all off the main thread.
///
/// Decoding uses `CGImageSourceCreateThumbnailAtIndex`, so a 12MP original
/// costs a cell-sized bitmap, not a 40MB decode. Feed prefetching calls
/// `prefetch(_:)` from `UICollectionViewDataSourcePrefetching`.
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
/// `ImagePipelineConcurrencyTests`. Here the synchronous members are
/// genuinely nonisolated and every read and write of the shared state — the
/// cache included, since `NSCache` is not `Sendable` — goes through one
/// `Mutex`, so a caller in any isolation is correct and the compiler checks it.
/// Nothing slow runs under the lock: fetching and decoding happen in a task.
public final class ImagePipeline: Sendable {
    public static let defaultMaxPixelSize = 1200

    private struct State {
        let cache: NSCache<NSURL, UIImage>
        var inflight: [URL: Task<UIImage, Error>] = [:]
        var prefetches: [URL: Task<Void, Never>] = [:]
    }

    private let fetcher: any ImageFetching
    private let maxPixelSize: Int
    private let state: Mutex<State>

    public init(fetcher: any ImageFetching, maxPixelSize: Int = ImagePipeline.defaultMaxPixelSize, countLimit: Int = 300) {
        self.fetcher = fetcher
        self.maxPixelSize = maxPixelSize
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = countLimit
        state = Mutex(State(cache: cache))
    }

    /// Cached-or-loaded image for `url`. Concurrent callers for the same URL
    /// share one fetch+decode.
    ///
    /// The shared task caches its own result and retires its own `inflight`
    /// entry, so a caller that stops waiting (cancelled, or a prefetch that
    /// was dropped) never leaves the entry behind for everyone else.
    public func image(for url: URL) async throws -> UIImage {
        let lookup: Lookup = state.withLock { state in
            if let cached = state.cache.object(forKey: url as NSURL) {
                return .cached(cached)
            }
            if let task = state.inflight[url] {
                return .loading(task)
            }
            let task = Task<UIImage, Error> { try await self.load(url) }
            state.inflight[url] = task
            return .loading(task)
        }
        switch lookup {
        case .cached(let image): return image
        case .loading(let task): return try await task.value
        }
    }

    private enum Lookup {
        case cached(UIImage)
        case loading(Task<UIImage, Error>)
    }

    /// The body of the one shared task per URL.
    private func load(_ url: URL) async throws -> UIImage {
        let image: UIImage
        do {
            let data = try await fetcher.fetchImageData(for: url)
            image = try Self.decodeDownsampled(data, maxPixelSize: maxPixelSize)
        } catch {
            state.withLock { $0.inflight[url] = nil }
            throw error
        }
        // ⚠️ Never earlier than `image(for:)`'s insertion: this task cannot take
        // the lock until the closure that created it has released it.
        state.withLock { state in
            state.cache.setObject(image, forKey: url as NSURL)
            state.inflight[url] = nil
        }
        return image
    }

    /// Synchronously returns the cached image if present — for cell
    /// configuration paths that must not suspend.
    public func cachedImage(for url: URL) -> UIImage? {
        state.withLock { $0.cache.object(forKey: url as NSURL) }
    }

    /// Seeds the cache with an already-decoded image under `url`. Used for
    /// optimistic rendering: a just-picked local image renders instantly
    /// under its freshly-minted CDN URL, before any network fetch.
    public func store(_ image: UIImage, for url: URL) {
        state.withLock { $0.cache.setObject(image, forKey: url as NSURL) }
    }

    // MARK: - Prefetching

    public func prefetch(_ urls: [URL]) {
        state.withLock { state in
            for url in urls where state.prefetches[url] == nil && state.cache.object(forKey: url as NSURL) == nil {
                state.prefetches[url] = Task { [weak self] in
                    _ = try? await self?.image(for: url)
                    self?.clearPrefetch(url)
                }
            }
        }
    }

    public func cancelPrefetch(_ urls: [URL]) {
        state.withLock { state in
            for url in urls {
                state.prefetches.removeValue(forKey: url)?.cancel()
            }
        }
    }

    /// Prefetches asked for and not yet finished or cancelled.
    var pendingPrefetchCount: Int {
        state.withLock { $0.prefetches.count }
    }

    private func clearPrefetch(_ url: URL) {
        state.withLock { $0.prefetches[url] = nil }
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
