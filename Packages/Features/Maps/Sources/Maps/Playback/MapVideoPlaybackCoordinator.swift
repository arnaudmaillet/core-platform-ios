import CoreModels
import MediaPlayback
import UIKit

/// Decides which of the visible video pins autoplay — the map analog of the
/// snap feed's `SnapLifecycleDispatcher`. At most `maxConcurrent` (1–3) play at
/// once, chosen by the caller's priority order (most central first); the rest
/// stay as still thumbnails. Playback runs through a small shared `AVPlayer`
/// pool, so cost is bounded regardless of pin density — the reason a UIKit
/// annotation map can host live video at all.
@MainActor
final class MapVideoPlaybackCoordinator {
    /// One playable pin: its id, a looping clip URL, and the annotation view
    /// whose `videoRenderView` receives the player.
    struct Candidate {
        let id: PostID
        let url: URL
        /// ⚠️ ANY host, not `MapAnnotationView`.
        ///
        /// Typing this as the lone-pin view excluded every cluster, and on the
        /// mock corpus that meant the path never ran at all: all three video
        /// pins in the default viewport were inside clusters. A cluster's face
        /// is one of its members' posts, and representatives are kind-neutral,
        /// so a video post leading a group is ordinary rather than exotic.
        let host: any MapVideoHost
    }

    private let pool: VideoPlaybackController
    private var maxConcurrent: Int
    /// Currently-playing pins → the view their player is bound to.
    private var playing: [PostID: any MapVideoHost] = [:]
    /// AND of the facts that gate playback (tab frontmost, no feed presented,
    /// app foregrounded).
    private var isSurfaceVisible = true

    init(pool: VideoPlaybackController, maxConcurrent: Int = 3) {
        self.pool = pool
        #if DEBUG
        // `-map-video-concurrency <n>` raises the cap for measurement. The
        // shipped default stays 3; this exists because "can we play more?" is a
        // question no amount of reading answers.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-map-video-concurrency"),
           index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
            self.maxConcurrent = max(1, value)
            return
        }
        #endif
        self.maxConcurrent = maxConcurrent
    }

    /// Reconciles playback against the current candidates (already ranked). Stops
    /// pins that dropped out of the top set or off screen; starts newly chosen
    /// ones. Idempotent — safe to call on every pan settle / annotation add.
    func update(candidates: [Candidate]) {
        let chosen = isSurfaceVisible ? Array(candidates.prefix(maxConcurrent)) : []
        let chosenIDs = Set(chosen.map(\.id))

        for (id, view) in playing where !chosenIDs.contains(id) {
            stop(id: id, view: view)
        }
        for candidate in chosen where playing[candidate.id] == nil {
            start(candidate)
        }
    }

    /// Stops the player bound to a specific render view — used when MapKit
    /// recycles the annotation view out from under us.
    func stop(_ renderView: VideoRenderView) {
        pool.stop(renderView)
        if let id = playing.first(where: { $0.value.videoRenderView === renderView })?.key {
            playing[id]?.endVideoPreview()
            playing[id] = nil
        }
    }

    /// Tab hidden / feed presented over the map / app backgrounded. Stops all
    /// playback while invisible; the next `update` re-selects when visible
    /// again. `keeping` exempts one pin from the sweep — the tapped pin whose
    /// live preview the hero transition is still flying; the caller stops it
    /// via `stopAll()` once the flight lands.
    func setSurfaceVisible(_ visible: Bool, keeping kept: PostID? = nil) {
        guard visible != isSurfaceVisible else { return }
        isSurfaceVisible = visible
        guard !visible else { return }
        for (id, view) in playing where id != kept {
            stop(id: id, view: view)
        }
    }

    /// Whether `id` is previewing live RIGHT NOW — the same fact
    /// `mirrorLivePreview` acts on, asked without acting on it.
    ///
    /// The hero seam needs it one step earlier than the mirror: the destination
    /// is told whether the card will fly a player while the transition
    /// controller is still being built, and the only way to answer by mirroring
    /// would be to mirror onto a card that does not exist yet.
    ///
    /// ⚠️ BOTH HALVES, because `playing` means SELECTED, not rendering. A pin
    /// is entered there the instant it is chosen, before the asynchronous
    /// `play` has opened anything — and on the default mock corpus that open
    /// never succeeds at all (`mock://video/...` is not a decodable asset, which
    /// is what `-rich-media` exists to fix). Asking membership alone would
    /// answer "live" for three pins that are showing a sprite sheet and nothing
    /// else, which is precisely the configuration this question was added for.
    ///
    /// The pool's answer is the mirror's own precondition, so this is exactly
    /// "would `mirrorLivePreview` take?" — and the two cannot drift into two
    /// different ideas of what live means.
    func isLivePreviewing(_ id: PostID) -> Bool {
        guard let host = playing[id] else { return false }
        return pool.hasPlayer(in: host.videoRenderView)
    }

    /// Mirrors the live preview of `id` (if it is playing) onto `view` — the
    /// hero transition's flight card — so the flight carries the same player,
    /// frame-synced, instead of a frozen copy. Returns whether a live preview
    /// was actually mirrored.
    func mirrorLivePreview(of id: PostID, to view: VideoRenderView) -> Bool {
        guard let host = playing[id] else { return false }
        return pool.mirror(from: host.videoRenderView, to: view)
    }

    func stopAll() {
        for (id, view) in playing { stop(id: id, view: view) }
    }

    // MARK: - Internals

    private func start(_ candidate: Candidate) {
        playing[candidate.id] = candidate.host
        candidate.host.beginVideoPreview()
        let view = candidate.host.videoRenderView
        let url = candidate.url
        // Return the player to the pool for this view if the pin scrolls off.
        candidate.host.onReuse = { [weak self] in self?.stop(view) }
        // ⚠️ `scope:` IS NOT OPTIONAL HERE, and passing nil was a real defect.
        //
        // The pool shares one player between two surfaces when the asset AND
        // the scope match — and `nil == nil` matches. Every map marker passed
        // nil while the mock gave every video pin the same fixture URL, so what
        // would have looked like three concurrent players was ONE player fanned
        // out to three surfaces: three views drawing one decoder on one clock.
        // Any "three videos are fine" reading taken before this line would have
        // been a measurement of one video.
        //
        // The post id is the right scope: two surfaces showing the SAME post — a
        // marker and the flight card it hands off to — should share, and two
        // different posts that happen to carry the same file (a repost) must not.
        //
        // `peakBitRate` mirrors the grid's cap. A preview loop is contracted at
        // <=300 KB so this never binds on a well-formed asset; it bounds the
        // damage when a pin is pointed at something else.
        Task { await pool.play(url, in: view, peakBitRate: 600_000, scope: candidate.id.rawValue) }
    }

    private func stop(id: PostID, view: any MapVideoHost) {
        pool.stop(view.videoRenderView)
        view.endVideoPreview()
        playing[id] = nil
    }
}
