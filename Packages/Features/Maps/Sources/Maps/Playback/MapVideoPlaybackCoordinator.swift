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
        let view: MapAnnotationView
    }

    private let pool: VideoPlaybackController
    private let maxConcurrent: Int
    /// Currently-playing pins → the view their player is bound to.
    private var playing: [PostID: MapAnnotationView] = [:]
    /// AND of the facts that gate playback (tab frontmost, no feed presented,
    /// app foregrounded).
    private var isSurfaceVisible = true

    init(pool: VideoPlaybackController, maxConcurrent: Int = 3) {
        self.pool = pool
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

    /// Mirrors the live preview of `id` (if it is playing) onto `view` — the
    /// hero transition's flight card — so the flight carries the same player,
    /// frame-synced, instead of a frozen copy. Returns whether a live preview
    /// was actually mirrored.
    func mirrorLivePreview(of id: PostID, to view: VideoRenderView) -> Bool {
        guard let pinView = playing[id] else { return false }
        return pool.mirror(from: pinView.videoRenderView, to: view)
    }

    func stopAll() {
        for (id, view) in playing { stop(id: id, view: view) }
    }

    // MARK: - Internals

    private func start(_ candidate: Candidate) {
        playing[candidate.id] = candidate.view
        candidate.view.beginVideoPreview()
        let view = candidate.view.videoRenderView
        let url = candidate.url
        // Return the player to the pool for this view if the pin scrolls off.
        candidate.view.onReuse = { [weak self] in self?.stop(view) }
        Task { await pool.play(url, in: view) }
    }

    private func stop(id: PostID, view: MapAnnotationView) {
        pool.stop(view.videoRenderView)
        view.endVideoPreview()
        playing[id] = nil
    }
}
