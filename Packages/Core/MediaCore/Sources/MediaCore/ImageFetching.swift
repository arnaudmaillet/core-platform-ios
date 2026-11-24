import CacheKit
import CoreModels
import Foundation
import UIKit

/// Byte-level image source. The pipeline owns caching, coalescing, and
/// decoding; fetchers only produce encoded bytes.
public protocol ImageFetching: Sendable {
    func fetchImageData(for url: URL) async throws -> Data
    /// The bytes for `url`, and whether they are the real image. `context`
    /// is the pipeline's fill: its priority, and its changes, for a fetcher
    /// that can pass them on (`URLSessionTask.priority`). The default calls
    /// `fetchImageData(for:)` and calls the bytes real.
    func fetchImage(for url: URL, context: CacheFillContext?) async throws -> ImageFetchResult
}

extension ImageFetching {
    public func fetchImage(for url: URL, context: CacheFillContext?) async throws -> ImageFetchResult {
        ImageFetchResult(data: try await fetchImageData(for: url), isCacheable: true)
    }
}

/// What a fetcher hands the pipeline.
public struct ImageFetchResult: Sendable {
    public let data: Data
    /// `false` for a stand-in (a placeholder a fetcher fell back to): the
    /// pipeline shows it but never stores it under the real image's key.
    public let isCacheable: Bool

    public init(data: Data, isCacheable: Bool) {
        self.data = data
        self.isCacheable = isCacheable
    }
}

/// Production fetcher: plain URLSession GET against the CDN.
///
/// `hostRewrite` handles delivery URLs hosted on a client-unreachable host
/// (e.g. a local fleet's Docker-internal `minio:9000`): the host is rewritten
/// to a reachable one, and the original host is sent as the `Host` header in
/// case the object store validates it.
public struct URLSessionImageFetcher: ImageFetching {
    /// The images' own session (#894): no `URLCache` (the pipeline's disk
    /// cache replaces it, so no image is stored twice), and a cap on
    /// connections per host so a long prefetch never starves what is on
    /// screen. Priorities travel per task (`CacheFillPriority`).
    public static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

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
        session: URLSession = URLSessionImageFetcher.imageSession,
        timeout: TimeInterval? = nil
    ) {
        self.session = session
        self.hostRewrite = hostRewrite
        self.timeout = timeout
    }

    public func fetchImageData(for url: URL) async throws -> Data {
        try await fetch(url, context: nil)
    }

    public func fetchImage(for url: URL, context: CacheFillContext?) async throws -> ImageFetchResult {
        ImageFetchResult(data: try await fetch(url, context: context), isCacheable: true)
    }

    private func fetch(_ url: URL, context: CacheFillContext?) async throws -> Data {
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
        // ⚠️ A P2 FETCH NEVER RUNS ON A CONSTRAINED NETWORK (#898). Low Data
        // Mode already stops P2 at the coordinator (no slot), but a path can
        // turn constrained while a fill runs: the system then refuses the
        // request instead of spending the viewer's data on a picture nobody
        // asked to see (`allowsConstrainedNetworkAccess`, WWDC19).
        let speculative = context?.priority == .speculative
        request.allowsConstrainedNetworkAccess = !speculative
        do {
            return try await load(request, context: context)
        } catch let error as URLError where speculative && error.networkUnavailableReason == .constrained {
            // Refused as P2, but raised since (the prefetched cell came on
            // screen): asked again as what it now is.
            guard let context, context.priority > .speculative else { throw error }
            request.allowsConstrainedNetworkAccess = true
            return try await load(request, context: context)
        }
    }

    private func load(_ request: URLRequest, context: CacheFillContext?) async throws -> Data {
        let (data, response) = try await session.data(for: request, delegate: context.map(TaskPriorityFollower.init))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// A fetcher that has nothing to fetch (#2516): every request fails. For a
/// pipeline that must exist but is never asked for a picture — a measuring
/// cell's probe, a screen built without the app's pipeline — so production
/// code needs no synthetic fetcher. A failed fetch leaves a slot on its
/// ground, as a dead URL does.
public struct UnavailableImageFetcher: ImageFetching {
    public init() {}

    public func fetchImageData(for url: URL) async throws -> Data {
        throw URLError(.unsupportedURL)
    }
}

/// Sets a download's `URLSessionTask.priority` from its fill, and follows the
/// fill's changes while it runs (a prefetched image scrolled on screen).
private final class TaskPriorityFollower: NSObject, URLSessionTaskDelegate, Sendable {
    private let context: CacheFillContext

    init(_ context: CacheFillContext) {
        self.context = context
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        task.priority = context.priority.urlSessionTaskPriority
        context.onPriorityChange { [weak task] priority in
            task?.priority = priority.urlSessionTaskPriority
        }
    }
}
