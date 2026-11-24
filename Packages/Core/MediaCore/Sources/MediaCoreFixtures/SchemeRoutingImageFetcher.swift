import CacheKit
import Foundation
import LaunchArguments
import MediaCore

// Mock media (#2516): linked by the mock app target and the tests, never by
// the production target, so the production app carries none of it.

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
    /// The URLs only `preferred` can answer truly. When it misses one of
    /// them (a deadline, a sheet that did not load), whatever answers instead
    /// is a stand-in: shown, never stored under the URL (#894), so a disk
    /// cache cannot keep the wrong poster across launches.
    private let preferredClaims: (@Sendable (URL) -> Bool)?

    public init(
        remote: any ImageFetching = URLSessionImageFetcher(timeout: 8),
        placeholder: any ImageFetching = PlaceholderImageFetcher(),
        preferred: (@Sendable (URL) async -> Data?)? = nil,
        preferredClaims: (@Sendable (URL) -> Bool)? = nil
    ) {
        self.remote = remote
        self.placeholder = placeholder
        self.preferred = preferred
        self.preferredClaims = preferredClaims
    }

    public func fetchImageData(for url: URL) async throws -> Data {
        try await fetchImage(for: url, context: nil).data
    }

    public func fetchImage(for url: URL, context: CacheFillContext?) async throws -> ImageFetchResult {
        var missedClaim = false
        if let preferred {
            if let data = await preferred(url) { return ImageFetchResult(data: data, isCacheable: true) }
            missedClaim = preferredClaims?(url) ?? false
        }
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
            let fetched = try await fetcher.fetchImage(for: url, context: context)
            return missedClaim ? ImageFetchResult(data: fetched.data, isCacheable: false) : fetched
        } catch where isRemote && !Self.isCancellation(error) {
            // The fallback half of the init's rule: a dead fixture host
            // degrades to the post's synthesized color instead of a blank.
            // Marked as a stand-in: the pipeline shows it for a short while
            // and never stores it under the real URL, so the real asset is
            // asked for again (#894).
            #if DEBUG
            // Logged HERE because the fallback makes the failure invisible
            // downstream: the cell receives bytes and `-media-audit`'s
            // failed-load line never fires. A silent rescue and a healthy
            // fetch must not read identically.
            if Self.logsFallbacks {
                print("[fixtures] remote image FAILED, placeholder served: \(url.absoluteString)")
            }
            #endif
            return ImageFetchResult(data: try await placeholder.fetchImageData(for: url), isCacheable: false)
        }
    }

    /// A fill nobody wants any more is cancelled: no stand-in for it.
    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    #if DEBUG
    private static let logsFallbacks = ProcessInfo.processInfo.arguments.contains { argument in
        argument == "-media-audit" || argument == "-media-log"
    }
    #endif

    #if DEBUG
    private static let debugMediaDelay: UInt64? = {
        guard let milliseconds = LaunchArgument.slowMedia.value().flatMap({ UInt64($0) }) else { return nil }
        return milliseconds * NSEC_PER_MSEC
    }()
    #endif
}
