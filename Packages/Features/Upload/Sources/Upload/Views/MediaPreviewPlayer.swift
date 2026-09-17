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
    /// Plays an ARRANGEMENT of a file in `surface`: its pieces end to end, in
    /// order, each at its own rate, as one item — the very composition the
    /// export builds. An empty plan is the file as shot.
    ///
    /// ⚠️ **THE ITEM'S SECONDS ARE THE ARRANGEMENT'S PLAYED SECONDS** — the
    /// track's own clock. A piece boundary is an edit inside the item, not a seek
    /// in the file, which is what ended the pause the author saw between
    /// re-ordered pieces.
    ///
    /// ⚠️ **BINDS IF NOTHING IS BOUND, OTHERWISE SWAPS THE ITEM IN PLACE**, keeping
    /// the surface's last frame and a pause the author asked for. `landing` is
    /// read after everything asynchronous, just before the item goes in: where
    /// to begin and what to loop, or nil to abandon a load the screen has moved
    /// past.
    func load(
        _ plan: VideoExportPlan, in surface: VideoRenderView,
        landing: @escaping @MainActor () -> VideoLoadLanding?
    ) async

    /// Loops a stretch of the arrangement's PLAYED seconds — the few seconds
    /// around a cut while its transition is chosen — or, with nil, the whole
    /// item again. Never starts or stops the clip.
    ///
    /// ⚠️ **NO DEFAULT IMPLEMENTATION, ON PURPOSE.** A stub that inherited a
    /// silent one could not say whether the screen ever asked.
    func setLoopRange(_ range: ClosedRange<Double>?, in surface: VideoRenderView)

    /// Shows the file as shot, AT ONCE, in place of the arrangement — for a trim
    /// handle being dragged, which may stand on film the arrangement does not
    /// contain. While it is shown, the item's seconds are the FILE's.
    func showAsShot(_ file: URL, in surface: VideoRenderView, atSourceSeconds seconds: Double)

    /// Unbinds whatever this surface holds and returns the player.
    func stop(_ surface: VideoRenderView)

    /// Pauses or resumes without giving the player back, so the playhead keeps
    /// its place.
    func setPaused(_ paused: Bool, in surface: VideoRenderView)

    /// Whether the clip in `surface` is stopped. Nil when nothing is bound.
    func isPaused(in surface: VideoRenderView) -> Bool?

    /// How many seconds of its item the clip in `surface` covers per second:
    /// zero unless it is really playing.
    func advancingRate(in surface: VideoRenderView) -> Double

    /// Whether this surface currently holds a player at all.
    func isBound(_ surface: VideoRenderView) -> Bool

    /// Where the player in `surface` has got to, in seconds of its ITEM.
    ///
    /// ⚠️ **NIL IS AN ORDINARY ANSWER, NOT A FAILURE.** Nothing bound yet happens
    /// on the first frames after a page settles. A caller draws nil as "not
    /// yet", never as an error.
    func playheadSeconds(in surface: VideoRenderView) -> Double?

    /// Moves the player in `surface` to `seconds` of its ITEM.
    ///
    /// ⚠️ **BY SECONDS, NOT BY A FRACTION OF THE LENGTH.** A fraction needs the
    /// item to know how long it is, and an item swapped in a moment ago may not
    /// — every seek asked in that window used to be dropped.
    ///
    /// ⚠️ **AS TOLERANT AS THE CALLER SAYS, AND THE CALLER KNOWS HOW FAST THE
    /// FINGER IS GOING.** An exact seek decodes forward from the nearest keyframe
    /// and a track being scrolled asks again long before that finishes; a loose
    /// one lands on a keyframe and does not move at all under a slow drag. See
    /// `MediaTimelining.seekTolerance`, which turns the distance a sample moved
    /// into the slack it is worth.
    func seek(toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double)

    /// Frames of `file` at the given SOURCE seconds, keyed by the second asked
    /// for.
    ///
    /// ⚠️ **BY TIME, NOT BY COUNT — AND THAT IS CHARTER T2.** This used to be
    /// "give me N frames across the clip", which forces the caller to decide the
    /// whole strip at once. A timeline that scrolls cannot afford to: a
    /// four-minute clip is two hundred and sixty tiles, 52 MB of decoded pixels
    /// for a band 74pt tall, nearly all of it off screen. Asking by time lets the
    /// track decode the window a person is looking at and nothing else.
    ///
    /// `spacing` is how far apart the strip's tiles are, which is what the
    /// generator's tolerance is derived from — see `VideoFilmstrip.tolerance`.
    ///
    /// ⚠️ Best-effort. A missing entry is a tile that keeps whatever it had, and
    /// an empty answer is a plain rectangle the handles still work on: the frames
    /// are how the author aims, not what they are editing.
    func frames(
        of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
    ) async -> [Double: UIImage]

    /// Draws the arrangement playing in `surface` with `look` over the whole of
    /// it, WITHOUT a new item — a slider dragged across a video must not rebuild
    /// the player sixty times a second. A paused clip shows the change too.
    func setLiveLook(_ look: FrameLook, in surface: VideoRenderView)

    /// Lets the clip in `surface` be heard, or silences it. Every clip starts
    /// silent; one carrying a song is the reason to un-mute.
    func setMuted(_ muted: Bool, in surface: VideoRenderView)

    /// The song's level and the film's own, live, both 0...1.
    func setMixLevels(music: Double, original: Double, in surface: VideoRenderView)
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

    func load(
        _ plan: VideoExportPlan, in surface: VideoRenderView,
        landing: @escaping @MainActor () -> VideoLoadLanding?
    ) async {
        // An arrangement is never shared — the controller registers it under no
        // URL. There is one player and one page; sharing is a feed concern.
        await controller.load(plan, in: surface, landing: landing)
    }

    func setLoopRange(_ range: ClosedRange<Double>?, in surface: VideoRenderView) {
        controller.setLoopRange(range, in: surface)
    }

    func showAsShot(_ file: URL, in surface: VideoRenderView, atSourceSeconds seconds: Double) {
        controller.showAsShot(file, in: surface, at: seconds)
    }

    func stop(_ surface: VideoRenderView) {
        controller.stop(surface)
    }

    func setPaused(_ paused: Bool, in surface: VideoRenderView) {
        _ = controller.setPaused(paused, in: surface)
    }

    func playheadSeconds(in surface: VideoRenderView) -> Double? {
        controller.playheadSeconds(in: surface)
    }

    func seek(toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double) {
        // ⚠️ **FORWARDED, AND FOR ONE COMMIT IT WAS NOT.** This body read
        // `controller.seek(toFraction:in:)` — the parameter accepted and
        // dropped, with no warning of any kind — so every seek took the
        // controller's 0.25s default. That killed charter T7 outright (a
        // creeping finger asks for 0.02 and got 0.25, which lands on keyframes,
        // which is the dead-feeling track the rule exists to prevent).
        //
        // ⚠️ **AND NO TEST COULD SEE IT.** The charter-T7 assertions read the
        // tolerance off a STUB that records it faithfully, while the one real
        // implementation threw it away — the repository's own
        // `laundered-assertion-trap`, wearing an adapter. `MediaPreviewPlayerTests`
        // now asks this object.
        controller.seek(
            toSeconds: seconds, in: surface, toleranceSeconds: toleranceSeconds
        )
    }

    func isPaused(in surface: VideoRenderView) -> Bool? {
        controller.isPaused(in: surface)
    }

    func isBound(_ surface: VideoRenderView) -> Bool {
        controller.hasPlayer(in: surface)
    }

    func advancingRate(in surface: VideoRenderView) -> Double {
        controller.advancingRate(in: surface)
    }

    /// ⚠️ **A SEPARATE GENERATOR, NOT THE CONTROLLER'S.**
    /// `VideoPlaybackController.previewFrame` caches generators and would be the
    /// obvious reuse — but it takes a FRACTION, needs a `VideoRenderView` already
    /// bound to that same controller, and re-sets `maximumSize` per call. A
    /// filmstrip asks for many exact times on a file that may not be playing.
    private let filmstrip = VideoFilmstrip()

    func frames(
        of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
    ) async -> [Double: UIImage] {
        await filmstrip.frames(
            of: file, atSourceSeconds: seconds, height: height, spacing: spacing
        )
    }

    /// ⚠️ **FORWARDED AS-IS — THE CONTROLLER'S BODY IS STILL A STUB** that
    /// changes nothing (the live-look slice fills it there, not here).
    func setLiveLook(_ look: FrameLook, in surface: VideoRenderView) {
        controller.setLiveLook(look, in: surface)
    }

    /// ⚠️ **FORWARDED AS-IS — THE CONTROLLER'S BODY IS STILL A STUB.** The
    /// soundtrack slice fills it, and switches the audio session to `.playback`
    /// here while a clip is heard (and back to `.ambient` on stop): a player
    /// un-muted under `.ambient` is silenced by the ring switch.
    func setMuted(_ muted: Bool, in surface: VideoRenderView) {
        controller.setMuted(muted, in: surface)
    }

    /// ⚠️ **FORWARDED AS-IS — THE CONTROLLER'S BODY IS STILL A STUB** (the
    /// soundtrack slice fills it).
    func setMixLevels(music: Double, original: Double, in surface: VideoRenderView) {
        controller.setMixLevels(music: music, original: original, in: surface)
    }

    #if DEBUG
    /// Internal for tests: how many players this screen's pool is holding.
    var debugActivePlayerCount: Int { controller.activePlayerCount }
    /// Internal for tests: how long the item the controller is running lasts.
    func debugItemSeconds(in surface: VideoRenderView) -> Double? {
        controller.playhead(in: surface)?.seconds
    }
    /// Internal for tests: where the item the controller is running stops, or
    /// nil when it plays to its end.
    func debugItemEnd(in surface: VideoRenderView) -> Double? {
        guard let end = controller.debugItem(in: surface)?.forwardPlaybackEndTime, end.isValid else {
            return nil
        }
        return end.seconds
    }
    /// Internal for tests: what the controller underneath was actually asked for.
    var debugLastSeekToleranceSeconds: Double? { controller.debugLastSeekToleranceSeconds }
    #endif
}
