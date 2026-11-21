#if MOCK_BACKEND
import AVFoundation
import CacheKit
import CoreModels
import CoreNetworkingMocks
import CoreStorage
import Foundation
import LaunchArguments
import MediaCore
import MediaPlayback
import UIKit

// Media's mock half (#2391): the image fetcher and the video source that read
// the mock corpus's bundled photos and clips. Mock builds only: the
// production target links no mock and ships none of its media.
extension AppContainer {
    func makeMockImageFetcher() -> any ImageFetching {
        // Scheme-routing, not plain placeholder: under `-rich-media` the
        // avatars are real `https://` photographs beside the `mock://`
        // assets, and each has to reach the right fetcher.
        SchemeRoutingImageFetcher(
            placeholder: PlaceholderImageFetcher(bundledPhoto: { MockPhotoCatalog.shared.fileURL(forPhoto: $0) }),
            preferred: Self.bakedPreviewPoster,
            preferredClaims: Self.claimsBakedPoster
        )
    }

    /// Mock mode synthesizes deterministic clips for `mock://video/…` URLs.
    func makeMockVideoSource() -> any VideoSource {
        #if DEBUG
        if Self.servesRemoteClips {
            return PlaceholderVideoFetcher(bundledClip: { Self.remoteClip(for: $0) })
        }
        #endif
        return PlaceholderVideoFetcher(bundledClip: { MockClipCatalog.shared.fileURL(forVideo: $0) })
    }

    /// Resolves `mock://preview/<clip>` from the map's own preview catalogue.
    ///
    /// A video post's poster is the frame the page shows until the first frame
    /// decodes, and the wire has no frame of the clip to give. The marker's
    /// baked sheet does — its frame zero IS that clip's opening — so the poster
    /// and the preview are one picture rather than two, and a flight that lands
    /// on the page does not change the subject.
    ///
    /// ⚠️ Whole-sheet decode, then crop, then PNG. It runs once per clip and the
    /// pipeline caches the result by URL, so the cost is four clips' worth of
    /// decode over a session rather than one per post.
    @MainActor
    private static func bakedPreviewPoster(_ url: URL) async -> Data? {
        let text = url.absoluteString
        // A clip with no baked sheet still has a first frame — its own. Decoded
        // from the asset rather than substituted with a stock photograph, which
        // is the whole point of both schemes.
        if let source = MockMediaFixtures.frameZeroSource(of: text) {
            return await frameZero(ofClipAt: source)
        }
        guard text.hasPrefix(MockMediaFixtures.previewPosterScheme) else { return nil }
        // ⚠️ THE PATH, NOT THE REST OF THE STRING. The map stamps its pin URLs
        // with `?mock-kind=video`, and taking everything after the scheme made
        // that query part of the clip's NAME — every lookup missing silently,
        // every video marker falling through to its ground.
        let clip = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        // ⚠️ THE OPENING SEGMENT, by the SAME rule the seeding uses. `first` is
        // the bundle's enumeration order, which is not the film's — so the
        // poster resolved one segment while the marker wore another, and the
        // two "frame zeros" were two different frames.
        guard let id = MockMediaFixtures.openingSegment(ofClip: clip, in: mapPreviewCatalog.ids),
              let art = try? await mapPreviewCatalog.art(for: id),
              let frame = art.firstFrame()
        else {
            // Kept: a miss here is silent otherwise, and the page simply shows
            // black — which reads as a slow video rather than as a poster that
            // never resolved. Sheets are 172x172 cells, one per clip
            // (`clip-01-0` for `mock://preview/clip-01`).
            #if DEBUG
            print("[poster] MISS clip=\(clip) ids=\(mapPreviewCatalog.ids.count)")
            #endif
            return nil
        }
        return frame.pngData()
    }

    /// The first frame of a clip, decoded from the asset.
    ///
    /// ⚠️ TOLERANT ON PURPOSE, in both directions. `requestedTimeToleranceAfter`
    /// is `.positiveInfinity` because an HLS ladder has no frame at exactly
    /// zero and an exact request simply fails; and the whole thing is wrapped in
    /// a timeout because these are PUBLIC TEST HOSTS — the same rule the image
    /// fetcher already keeps, that a fixture convenience must never be the
    /// reason nothing shows. A miss returns nil and the surface falls to its
    /// next rung, which is black.
    /// The poster URLs only `bakedPreviewPoster` answers truly: a miss there
    /// (its 8 s deadline, a sheet that did not load) is a stand-in the image
    /// disk cache must not keep across launches.
    private nonisolated static func claimsBakedPoster(_ url: URL) -> Bool {
        let text = url.absoluteString
        return MockMediaFixtures.frameZeroSource(of: text) != nil || text.hasPrefix(MockMediaFixtures.previewPosterScheme)
    }

    private nonisolated static func frameZero(ofClipAt source: String) async -> Data? {
        guard let named = URL(string: source) else { return nil }
        // A bundled clip (`mock://video/<clip>`) is read from its file (#1850).
        let url = MockClipCatalog.shared.fileURL(forVideo: named) ?? named
        let work = Task.detached(priority: .utility) { () -> Data? in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .positiveInfinity
            generator.maximumSize = CGSize(width: 1080, height: 1080)
            guard let frame = try? await generator.image(at: .zero).image else { return nil }
            return UIImage(cgImage: frame).pngData()
        }
        // ⚠️ A DEADLINE, because these are PUBLIC TEST HOSTS. The same rule the
        // image fetcher already keeps: a fixture convenience must never be the
        // reason nothing shows.
        let timeout = Task.detached(priority: .utility) { () -> Data? in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            work.cancel()
            return nil
        }
        let data = await work.value
        timeout.cancel()
        guard let data else {
            #if DEBUG
            print("[poster] MISS frame0 src=\(source)")
            #endif
            return nil
        }
        return data
    }

    #if DEBUG
    /// `-video-cache-remote`: mock mode plays every clip from a public MP4
    /// over HTTP instead of the bundled file, so the video byte cache and the
    /// feed's preload (#895) run in the simulator without a fleet. Each post
    /// gets its own `qa` query item, so two posts never share a cache key.
    /// Needs network; pair it with `-cache-audit` to read the cache's log.
    static let servesRemoteClips = DebugFlags.isOn("-video-cache-remote")

    /// Verified with a ranged GET (206, `video/mp4`), as `DebugMediaLibrary`'s
    /// real clips are.
    private nonisolated static let remoteClips = [
        "https://media.w3.org/2010/05/sintel/trailer.mp4",
        "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4",
        "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4"
    ]

    private nonisolated static func remoteClip(for url: URL) -> URL? {
        // FNV-1a: stable across launches, unlike `Hasher`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let base = remoteClips[Int(hash % UInt64(remoteClips.count))]
        return URL(string: base + "?qa=" + String(hash, radix: 16))
    }
    #endif
}
#endif
