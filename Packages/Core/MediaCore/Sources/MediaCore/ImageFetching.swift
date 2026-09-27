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
    private let timeout: TimeInterval?

    /// `timeout` caps the per-request wait; nil keeps URLSession's default
    /// (60s). Production leaves it nil — a slow CDN is still the CDN. The
    /// fixture path sets it tight, because a PUBLIC TEST HOST that accepts
    /// the connection and never answers (measured: picsum's edge completing
    /// TLS and then hanging) otherwise pins every image slot for a minute
    /// each, and the whole feed reads as "media doesn't load".
    public init(
        hostRewrite: HostRewrite? = nil,
        session: URLSession = .shared,
        timeout: TimeInterval? = nil
    ) {
        self.session = session
        self.hostRewrite = hostRewrite
        self.timeout = timeout
    }

    public func fetchImageData(for url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        if let timeout {
            request.timeoutInterval = timeout
        }
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

    /// The default remote carries a TIGHT timeout, and remote failures fall
    /// back to the placeholder below — both halves of one rule the video
    /// fixtures already state: a test-fixture convenience must never be the
    /// reason nothing shows. `-rich-media` leans on public test hosts, and
    /// when one dies mid-session (picsum: TLS completes, response never
    /// comes) every photo and every clip poster used to become a permanent
    /// blank behind a 60-second wait each. Degrading to the synthesized
    /// color keeps the post VISIBLE and honest; `-media-audit` still logs
    /// the failed URL, so an outage stays observable rather than masked.
    /// Answered BEFORE either fetcher, for URLs the app can satisfy from what it
    /// already holds.
    ///
    /// The case it exists for: a video post's poster. The wire has no frame of
    /// the clip to offer, so the mock used to point at an unrelated photograph
    /// — and the viewer saw it, because a poster is what a page shows until the
    /// first frame decodes. The app HAS the right picture: the marker's baked
    /// preview, whose frame zero is that clip's own opening. Nothing in this
    /// file can know that; a closure can be handed it.
    private let preferred: (@Sendable (URL) async -> Data?)?

    public init(
        remote: any ImageFetching = URLSessionImageFetcher(timeout: 8),
        placeholder: any ImageFetching = PlaceholderImageFetcher(),
        preferred: (@Sendable (URL) async -> Data?)? = nil
    ) {
        self.remote = remote
        self.placeholder = placeholder
        self.preferred = preferred
    }

    public func fetchImageData(for url: URL) async throws -> Data {
        if let preferred, let data = await preferred(url) { return data }
        let scheme = url.scheme?.lowercased()
        let isRemote = scheme == "http" || scheme == "https"
        let fetcher = isRemote ? remote : placeholder
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
        do {
            return try await fetcher.fetchImageData(for: url)
        } catch where isRemote {
            // The fallback half of the init's rule: a dead fixture host
            // degrades to the post's synthesized color instead of a blank.
            // The pipeline caches what we return — right for an outage that
            // outlives any one request; a relaunch retries the real asset.
            #if DEBUG
            // Logged HERE because the fallback makes the failure invisible
            // downstream: the cell receives bytes and `-media-audit`'s
            // failed-load line never fires. A silent rescue and a healthy
            // fetch must not read identically.
            if Self.logsFallbacks {
                print("[fixtures] remote image FAILED, placeholder served: \(url.absoluteString)")
            }
            #endif
            return try await placeholder.fetchImageData(for: url)
        }
    }

    #if DEBUG
    private static let logsFallbacks = ProcessInfo.processInfo.arguments.contains { argument in
        argument == "-media-audit" || argument == "-media-log"
    }
    #endif

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
