import Foundation
import UIKit

/// Byte-level image source. The pipeline owns caching, coalescing, and
/// decoding; fetchers only produce encoded bytes.
public protocol ImageFetching: Sendable {
    func fetchImageData(for url: URL) async throws -> Data
}

/// Production fetcher: plain URLSession GET against the CDN.
public struct URLSessionImageFetcher: ImageFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchImageData(for url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Deterministic offline fetcher for mock mode: renders a solid-color image
/// derived from the URL, honoring `w`/`h` query parameters. Keeps the entire
/// media pipeline exercised (decode, downsample, cache, prefetch) with zero
/// network.
public struct PlaceholderImageFetcher: ImageFetching {
    public init() {}

    public func fetchImageData(for url: URL) async throws -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let width = components?.queryItems?.first { $0.name == "w" }.flatMap { Int($0.value ?? "") } ?? 256
        let height = components?.queryItems?.first { $0.name == "h" }.flatMap { Int($0.value ?? "") } ?? 256

        // Stable hue from the URL path so every post/avatar keeps its color.
        var hasher = Hasher()
        hasher.combine(url.path)
        let hue = CGFloat(abs(hasher.finalize() % 360)) / 360

        let size = CGSize(width: min(width, 1600), height: min(height, 1600))
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.pngData { context in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.82, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image
    }
}
