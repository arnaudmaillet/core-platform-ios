import CoreModels
import FeedInterface
import Foundation
import LaunchArguments
import MediaPlayback
import PostSurfaces

/// The playback warms: a map marker's clip started before the flight, its
/// paused first frame, and the posts a surface is about to open, with their
/// first comments. Built once by `FeedFeatureBuilder`.
@MainActor
struct FeedPlaybackWarms {
    private let repository: any FeedProviding
    private let videoPlayback: VideoPlaybackController?
    /// The builder's one warm of a post's first comments (#2002).
    private let postOpenWarm: PostOpenWarm?

    init(dependencies: FeedFeatureBuilder.Dependencies, postOpenWarm: PostOpenWarm?) {
        repository = dependencies.repository
        videoPlayback = dependencies.videoPlayback
        self.postOpenWarm = postOpenWarm
    }

    /// Starts `postID`'s page player now, at `seconds` into its clip — a finger
    /// has landed on its map marker (#646). Nil when the post is not hydrated
    /// yet (the map warms visible posts' DATA on every settle, so it usually
    /// is), when it is not a single clip, when autoplay is off, or without a
    /// player pool. The caller ends it: see `FlightPlaybackWarm.end(opened:)`.
    @MainActor
    public func warmPlayback(of postID: PostID, at seconds: TimeInterval?) -> (any FeedPlaybackWarm)? {
        let entry = repository.peekPost(postID)
        // Not gated on autoplay (#702): the flight lands on a full-screen post,
        // which plays whatever Autoplay says.
        guard let videoPlayback, let entry,
              let clip = FlightPlaybackWarm.warmableClip(of: entry) else {
            #if DEBUG
            if LaunchArgument.zoomLiveLog.isPassed() {
                print("[zoom-live] warm refused \(postID.rawValue): pool=\(videoPlayback != nil) "
                      + "autoplay=\(MediaPlaybackPolicy.autoplays) hydrated=\(entry != nil) "
                      + "attachments=\(entry?.post.attachments.map { $0.mimeType } ?? [])")
            }
            #endif
            return nil
        }
        let warm = FlightPlaybackWarm(pool: videoPlayback, url: clip.url, scope: clip.scope)
        warm.start(at: seconds)
        return warm
    }

    /// See `FeedFeatureBuilding.prerollPlayback` (#654).
    @MainActor
    public func prerollPlayback(of postID: PostID, at seconds: TimeInterval?) -> (any FeedPlaybackWarm)? {
        let process = ProcessInfo.processInfo
        let allowed = FlightPlaybackWarm.prerollAllowed(preloads: MediaPlaybackPolicy.preloads,
                                                        autoplays: MediaPlaybackPolicy.autoplays,
                                                        lowPower: process.isLowPowerModeEnabled,
                                                        thermal: process.thermalState)
        let entry = repository.peekPost(postID)
        // Not hydrated yet: the map warms its visible posts' data on the same
        // settle, and which ones a sweep reaches is not guaranteed. Asked for
        // here, so the map's next try finds it.
        if allowed, entry == nil {
            let repository = repository
            Task { await repository.prewarm([postID]) }
        }
        guard allowed, let videoPlayback, let entry,
              let clip = FlightPlaybackWarm.warmableClip(of: entry) else {
            #if DEBUG
            if LaunchArgument.zoomLiveLog.isPassed(in: process.arguments) {
                print("[zoom-live] preroll refused \(postID.rawValue): preloads=\(MediaPlaybackPolicy.preloads) "
                      + "autoplay=\(MediaPlaybackPolicy.autoplays) lowPower=\(process.isLowPowerModeEnabled) "
                      + "thermal=\(process.thermalState.rawValue) hydrated=\(entry != nil)")
            }
            #endif
            return nil
        }
        let warm = FlightPlaybackWarm(pool: videoPlayback, url: clip.url, scope: clip.scope)
        warm.start(at: seconds, pausedOnFirstFrame: true)
        return warm
    }

    public func prewarmPosts(_ ids: [PostID]) async {
        #if DEBUG
        // See `isColdOpenForced`: a warmed corpus seeds synchronously and the
        // cold path is unreachable, which is why it could only be filmed by
        // accident on a slow machine.
        guard !Self.isColdOpenForced else { return }
        #endif
        // The map's visible pins and the sound sheet's posts warm their first
        // comments too, queued behind what is on screen elsewhere (#2002).
        postOpenWarm?.warmLater(ids)
        await repository.prewarm(ids)
    }

    #if DEBUG
    /// `-feed-cold-open [ms]`: forces the path a FIRST open takes, and holds it
    /// open long enough to film.
    ///
    /// ⚠️ THE COLD PATH IS NORMALLY UNREACHABLE ON DEMAND, and that is the
    /// point of this. `prewarmVisiblePosts` warms up to 16 posts on every
    /// viewport settle, seconds before any tap, and the seed below is
    /// all-or-nothing — so whether a given pin opens cold depends on a Set's
    /// iteration order and on which sweep was cancelled by the next. A defect
    /// reachable only by luck is a defect nobody can prove fixed.
    ///
    /// It suppresses the prewarm, forbids the synchronous seed, and delays the
    /// hydration by `ms` (default 800). The delay sits on the POST fetch alone,
    /// not the transport, so the map's own markers stay fast and the window
    /// under test is the only slow thing.
    static var isColdOpenForced: Bool {
        LaunchArgument.feedColdOpen.isPassed()
    }
    #endif
}
