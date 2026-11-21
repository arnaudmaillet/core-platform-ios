import AVFoundation
import CacheKit
import CoreModels
import CoreStorage
import Foundation
import LaunchArguments
import MediaCore
import MediaPlayback
import UIKit

// Media (#2375): the image pipeline, the playback pools and their video source.
// Its properties are declared in `AppContainer.swift`, since an extension holds
// no stored property; they are built here.
extension AppContainer {
    /// Every playback pool made so far, held weakly (`sizedToPreference`), so
    /// a memory signal reaches them without making the ones not yet needed.
    private static let playbackPools = NSHashTable<VideoPlaybackController>.weakObjects()

    static func releasePlaybackMemory() {
        for pool in playbackPools.allObjects { pool.releaseIdleMemory() }
    }

    func makeImagePipeline() -> ImagePipeline {
        let fetcher: any ImageFetching
        switch environment {
        #if MOCK_BACKEND
        case .mock:
            fetcher = makeMockImageFetcher()
        #endif
        case .remote:
            fetcher = URLSessionImageFetcher(hostRewrite: HostRewrite(from: "minio:9000", to: "localhost:9000"))
        }
        return ImagePipeline(fetcher: fetcher, disk: Self.imageDisk, coordinator: cacheCoordinator)
    }

    /// The images' disk cache (#894). DEBUG `-slow-media` turns it off: that
    /// flag exists to film the states that only show while a picture is
    /// missing, and a disk hit would skip its delay after the first launch.
    /// `-image-disk-off` turns it off on its own.
    private static var imageDisk: ImageDiskLocation? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if LaunchArgument.slowMedia.isPassed(in: arguments) || LaunchArgument.imageDiskOff.isPassed(in: arguments) { return nil }
        #endif
        return .caches
    }

    /// Snap-feed video playback. Mock mode synthesizes deterministic clips for
    /// `mock://video/…` URLs; fleet mode passes delivery URLs straight to the
    /// player (a no-op today — the backend serves no video renditions yet).
    func makeVideoSource() -> any VideoSource {
        switch environment {
        #if MOCK_BACKEND
        case .mock:
            return makeMockVideoSource()
        #endif
        case .remote:
            return PassthroughVideoSource()
        }
    }

    /// A playback pool sized by Settings' player pool (#702), and resized
    /// live when it changes.
    static func sizedToPreference(_ pool: VideoPlaybackController) -> VideoPlaybackController {
        playbackPools.add(pool)
        let store = MediaPlaybackPreferencesStore.standard
        pool.resize(to: store.preferences.playerPool.size)
        NotificationCenter.default.addObserver(
            forName: .mediaPlaybackPreferencesDidChange, object: nil, queue: .main
        ) { [weak pool] _ in
            MainActor.assumeIsolated {
                pool?.resize(to: MediaPlaybackPreferencesStore.standard.preferences.playerPool.size)
            }
        }
        return pool
    }

    #if DEBUG
    /// Both playback pools, labelled, for the hero-transition audit — the one
    /// reader that needs to see them side by side. `mapsVideoPlayback` stays
    /// private; the audit reads census accessors only.
    var debugPlaybackPools: [(label: String, pool: VideoPlaybackController)] {
        [("feed", videoPlayback), ("maps", mapsVideoPlayback)]
    }
    #endif
}
