import Foundation
import MediaCore
import UIKit

// Mock media (#2516): linked by the mock app target and the tests, never by
// the production target, so the production app carries none of it.

/// Deterministic offline fetcher for mock mode: serves the bundled photo
/// behind a `mock://` URL when there is one, and otherwise renders a
/// solid-color image derived from the URL, honoring `w`/`h` query parameters.
/// Keeps the entire media pipeline exercised (decode, downsample, cache,
/// prefetch) with zero network.
public struct PlaceholderImageFetcher: ImageFetching {
    private let bundledPhoto: (@Sendable (URL) -> URL?)?

    /// - Parameter bundledPhoto: the real file behind a `mock://` URL, when the
    ///   app carries one (the mock corpus's photo galleries). Asked before
    ///   anything is synthesized; nil keeps every `mock://` synthetic. The
    ///   mirror of `PlaceholderVideoFetcher(bundledClip:)`.
    public init(bundledPhoto: (@Sendable (URL) -> URL?)? = nil) {
        self.bundledPhoto = bundledPhoto
    }

    public func fetchImageData(for url: URL) async throws -> Data {
        if let file = bundledPhoto?(url), let data = try? Data(contentsOf: file) { return data }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let width = components?.queryItems?.first { $0.name == "w" }.flatMap { Int($0.value ?? "") } ?? 256
        let height = components?.queryItems?.first { $0.name == "h" }.flatMap { Int($0.value ?? "") } ?? 256

        let hue = Self.hue(forPath: url.path)

        let size = CGSize(width: min(width, 1600), height: min(height, 1600))
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.pngData { context in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.82, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image
    }

    /// The colour's hue, in [0, 1), from the URL's path — the same on every
    /// launch, so an avatar keeps its colour.
    ///
    /// ⚠️ FNV-1a, NOT `Hasher`: Swift seeds `Hasher` per process, so every
    /// synthetic avatar changed colour at each launch (pink, then green, then
    /// orange for one profile) while the comment here promised a stable hue.
    /// The same trap `PlaceholderVideoFetcher`'s cache key fell into.
    static func hue(forPath path: String) -> CGFloat {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return CGFloat(hash % 360) / 360
    }
}
