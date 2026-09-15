import MediaPlayback
import UIKit

/// What the editor needs of a picked clip: playing it, and sampling it.
///
/// ⚠️ **NAMED FOR THE MEDIUM, NOT THE VERB — IT WAS `MediaPreviewPlaying` AND
/// GREW A SECOND JOB.** The trim strip needs frames, which is not playback but
/// is exactly as much "what this screen needs of a video", and exactly as
/// impossible for a test to do for real. Two seams would have meant two stubs
/// per test for one subject.
///
/// ⚠️ **A SEAM RATHER THAN A DIRECT CALL, BECAUSE A TEST CANNOT PLAY VIDEO.**
/// CI has no photo library and no camera, and a real `AVPlayer` bound to a
/// surface in an offscreen window decodes nothing anyone can assert on. What the
/// editor's tests need to know is narrower and entirely answerable: did this
/// page ask for playback, did the page it left get stopped, and does a
/// photograph ask for nothing at all. That is this protocol.
@MainActor
protocol MediaVideoPreviewing: AnyObject {
    /// Binds `file` to `surface` and starts it. Repeatable; a second call for
    /// the same surface supersedes the first.
    func play(_ file: URL, in surface: VideoRenderView) async

    /// Unbinds whatever this surface holds and returns the player.
    func stop(_ surface: VideoRenderView)

    /// Pauses or resumes without giving the player back, so the playhead keeps
    /// its place.
    func setPaused(_ paused: Bool, in surface: VideoRenderView)

    /// Whether this surface currently holds a player at all.
    func isBound(_ surface: VideoRenderView) -> Bool

    /// `count` frames spread evenly across the clip, for a trim strip.
    ///
    /// ⚠️ Best-effort and ORDERED. An empty answer is a strip with no pictures,
    /// which is a plain rectangle the handles still work on — the frames are how
    /// the author aims, not what they are editing.
    func filmstrip(of file: URL, count: Int, height: CGFloat) async -> [UIImage]
}

/// The real one: a `VideoPlaybackController` of this screen's very own.
///
/// ⚠️ **ITS OWN POOL, SIZED ONE — NEVER THE FEED'S.** Sharing the app-wide pool
/// would be the obvious move and it is the wrong one twice over. The feed sizes
/// its pool for a scrolling working set and evicts on that basis, so an editor
/// holding one of its players would either starve the feed or lose its own clip
/// to an eviction it cannot see. And this repo's one recorded player leak —
/// `profile-gallery-player-leak` — is entirely a story of surfaces outliving the
/// screen that made them: a pool owned by the screen dies with the screen, which
/// removes the failure mode rather than guarding against it.
///
/// One player because one page plays. The canvas holds every chosen medium, but
/// only the settled one is allowed to run; see `MediaEditorViewController`.
///
/// ⚠️ `PassthroughVideoSource`, not `PlaceholderVideoFetcher`. Everything
/// reaching here is a local file the library already vended — there is nothing
/// to resolve, and a source that synthesises over `mock://` would be answering a
/// question this screen never asks.
@MainActor
final class MediaPreviewPlayer: MediaVideoPreviewing {
    private let controller = VideoPlaybackController(
        source: PassthroughVideoSource(), poolSize: 1, capacity: 1
    )

    func play(_ file: URL, in surface: VideoRenderView) async {
        // `scope: nil` means "share with nobody". There is one player and one
        // page; sharing is a feed concern.
        await controller.play(file, in: surface)
    }

    func stop(_ surface: VideoRenderView) {
        controller.stop(surface)
    }

    func setPaused(_ paused: Bool, in surface: VideoRenderView) {
        _ = controller.setPaused(paused, in: surface)
    }

    func isBound(_ surface: VideoRenderView) -> Bool {
        controller.hasPlayer(in: surface)
    }

    /// ⚠️ **A SEPARATE GENERATOR, NOT THE CONTROLLER'S.**
    /// `VideoPlaybackController.previewFrame` caches generators and would be the
    /// obvious reuse — but it takes a FRACTION, needs a `VideoRenderView` already
    /// bound to that same controller, and re-sets `maximumSize` per call. A
    /// filmstrip asks for many exact times on a file that may not be playing.
    private let filmstrip = VideoFilmstrip()

    func filmstrip(of file: URL, count: Int, height: CGFloat) async -> [UIImage] {
        await filmstrip.frames(of: file, count: count, height: height)
    }

    #if DEBUG
    /// Internal for tests: how many players this screen's pool is holding.
    var debugActivePlayerCount: Int { controller.activePlayerCount }
    #endif
}
