import Foundation
import UIKit

/// Byte-level image source. The pipeline owns caching, coalescing, and
/// decoding; fetchers only produce encoded bytes.
public protocol ImageFetching: Sendable {
    func fetchImageData(for url: URL) async throws -> Data
}

/// Production fetcher: plain URLSession GET against the CDN.
///
/// `hostRewrite` handles delivery URLs hosted on a client-unreachable host
/// (e.g. a local fleet's Docker-internal `minio:9000`): the host is rewritten
/// to a reachable one, and the original host is sent as the `Host` header in
/// case the object store validates it.
public struct URLSessionImageFetcher: ImageFetching {
    private let session: URLSession
    private let hostRewrite: HostRewrite?

    public init(hostRewrite: HostRewrite? = nil, session: URLSession = .shared) {
        self.session = session
        self.hostRewrite = hostRewrite
    }

    public func fetchImageData(for url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        if let rewrite = hostRewrite?.apply(to: url) {
            request.url = rewrite.url
            if let hostHeader = rewrite.hostHeader {
                request.setValue(hostHeader, forHTTPHeaderField: "Host")
            }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Routes by URL scheme: `http(s)` goes to `remote`, everything else (notably
/// mock mode's `mock://`) to `placeholder`.
///
/// This is what lets the mock dataset's opt-in real-asset catalog
/// (`-rich-media`) load genuine photographs while the synthesized seeds keep
/// rendering offline — one dataset can mix both, and neither fetcher needs to
/// know the other exists. Without it, `PlaceholderImageFetcher` would paint a
/// flat color over every real URL and the fixtures would prove nothing.
public struct SchemeRoutingImageFetcher: ImageFetching {
    private let remote: any ImageFetching
    private let placeholder: any ImageFetching

    public init(
        remote: any ImageFetching = URLSessionImageFetcher(),
        placeholder: any ImageFetching = PlaceholderImageFetcher()
    ) {
        self.remote = remote
        self.placeholder = placeholder
    }

    public func fetchImageData(for url: URL) async throws -> Data {
        let scheme = url.scheme?.lowercased()
        let fetcher = scheme == "http" || scheme == "https" ? remote : placeholder
        #if DEBUG
        // `-slow-media <ms>`: holds every image back, so the states that only
        // exist WHILE a picture is missing can be seen at all.
        //
        // Mock mode's placeholder fetcher answers in microseconds and the real
        // catalog is cached after one launch, so the feed's "still loading"
        // spinner — which waits a quarter-second before appearing — could not
        // be reached from a script: it is correct for it never to show when
        // nothing is ever slow. This is the only way to film it, and it delays
        // the FETCH rather than faking the state, so everything downstream (the
        // grace, the cell, the surface) is the real path.
        if let delay = Self.debugMediaDelay { try? await Task.sleep(nanoseconds: delay) }
        #endif
        return try await fetcher.fetchImageData(for: url)
    }

    #if DEBUG
    private static let debugMediaDelay: UInt64? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-slow-media"),
              position + 1 < arguments.count,
              let milliseconds = UInt64(arguments[position + 1]) else { return nil }
        return milliseconds * NSEC_PER_MSEC
    }()
    #endif
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
