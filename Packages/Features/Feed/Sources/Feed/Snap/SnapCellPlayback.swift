import MediaPlayback
import QuartzCore
import UIKit

/// The viewer's hand on a post page's clip, and the clip's position fed back
/// to the media bar — moved out of `SnapFeedCell` (#857).
///
/// What it owns:
/// - the tap toggle, hold-to-pause and the sheet cover, with the flags that
///   say who paused the clip and so who may resume it;
/// - the playhead feed: a display link that publishes the watched clip's
///   position while the page is active on a clip (`onPlayhead`);
/// - the scrub: exact seeks under the thumb, the pause while it drags and the
///   resume once the seeks have landed, and the preview frame above it.
///
/// What it does NOT own, and why: starting, warming, parking, donating,
/// adopting and reclaiming the page's player stay in the cell. Those move
/// players and pool loans between the page, a hero flight's card and the
/// grid tile, and their order is the whole of their correctness.
///
/// Every call works on the WATCHED surface, asked of `surface` each time:
/// the card re-points it at every landing, reclaim and page turn, so a
/// surface captured once would go stale. Gates that read the page's own
/// layout (the tap territory, the engagement, whether the page plays video
/// at all) stay with the cell, which asks them first.
///
/// Tested without a screen against a real pool (`SnapCellPlaybackTests`).
@MainActor
final class SnapCellPlayback: NSObject {
    /// The pool the page plays through — the cell's `videoPlayback`.
    var pool: VideoPlaybackController?
    /// The watched surface (`mediaCard.renderView`), or nil once the page is
    /// gone.
    private let surface: () -> VideoRenderView?
    /// Whether the page is the active one.
    private let isActive: () -> Bool

    /// The playhead to draw: a fraction (nil when there is none to report)
    /// and the clip's length in seconds — `SnapChromeView.setMediaPlayhead`.
    var onPlayhead: ((Double?, Double) -> Void)?
    /// The scrub card is waiting for a frame, or has stopped waiting.
    var onScrubPreviewLoading: ((Bool) -> Void)?
    /// The scrub card's frame has landed.
    var onScrubPreviewPicture: ((CGImage) -> Void)?

    #if DEBUG
    /// The collection page the viewer is on, for the `-media-log` traces.
    var debugCurrentPage: () -> Int = { 0 }
    #endif

    init(surface: @escaping () -> VideoRenderView?, isActive: @escaping () -> Bool) {
        self.surface = surface
        self.isActive = isActive
        super.init()
    }

    // MARK: - The viewer's pauses

    /// Whether a hold is what stopped playback, so its end knows to resume.
    ///
    /// ⚠️ Recorded rather than assumed. A clip the viewer had ALREADY paused by
    /// tapping must not start playing because a later hold ended on it — the
    /// release undoes the hold, and nothing else.
    private var isHeldPaused = false
    /// Paused by `setCoveredBySheet`, and owed a resume by it.
    private var isSheetPaused = false

    /// Toggles the watched clip. Returns whether it is now paused, nil when
    /// there is no pool to ask.
    func toggle() -> Bool? {
        guard let pool, let view = surface() else { return nil }
        let paused = pool.togglePlayback(in: view)
        traceViewerPlayback("tap", paused: paused)
        return paused
    }

    /// The finger went down and stayed: stops the clip, but only one that is
    /// running.
    func beginHold() {
        guard let pool, let view = surface() else { return }
        // Only a clip that is actually running can be held. Holding a paused
        // one and letting go would otherwise start it.
        guard pool.isAdvancing(in: view) else { return }
        isHeldPaused = pool.setPaused(true, in: view)
        traceViewerPlayback("hold", paused: isHeldPaused)
    }

    /// The hold ended: resumes the clip if the hold is what stopped it.
    func endHold() {
        guard isHeldPaused, let pool, let view = surface() else { return }
        isHeldPaused = false
        pool.setPaused(false, in: view)
        traceViewerPlayback("release", paused: false)
    }

    /// Pauses the clip on `view` (the page's audible surface) while a sheet
    /// covers it, and resumes it after, but only if it was running when
    /// covered: a clip the viewer had paused stays paused. See
    /// `SnapFeedCell.setCoveredBySheet`.
    func setCovered(_ covered: Bool, on view: VideoRenderView) {
        guard let pool else { return }
        if covered {
            guard !isSheetPaused, pool.isAdvancing(in: view) else { return }
            isSheetPaused = pool.setPaused(true, in: view)
        } else if isSheetPaused {
            isSheetPaused = false
            pool.setPaused(false, in: view)
        }
    }

    /// What the finger did to the clip, for the leg no unit test can reach: a
    /// suite has no decoder, so "the player was told to stop" is all it can
    /// assert. `-media-log` says whether a player ANSWERED — the silent no-op
    /// this gesture spent a release doing is `answered=N`, and it looks
    /// identical from every other angle.
    private func traceViewerPlayback(_ action: String, paused: Bool) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-media-log") else { return }
        // A player that took the instruction now reads the OPPOSITE of the
        // state it was moved out of; one that never heard it reads unchanged.
        let advancing = surface().map { pool?.isAdvancing(in: $0) ?? false } ?? false
        print(String(format: "[page-play] %.3f %@ paused=%@ answered=%@ page=%d",
                     CACurrentMediaTime(), action, paused ? "Y" : "N",
                     advancing == paused ? "N" : "Y", debugCurrentPage()))
        #endif
    }

    // MARK: - The playhead feed

    /// Keeps the page strip's clip bar fed — the cell calls it while the page
    /// is active on a clip (`SnapFeedCell.updatePlayheadFeed`).
    ///
    /// ⚠️ A DISPLAY LINK, and only while it is earning its place: the page is
    /// active, its collection's current page carries a clip, and the strip is
    /// therefore drawn as that clip's bar. A playhead has no notification to
    /// hang off — it advances because time passes — so something has to ask,
    /// and asking on the screen's own beat is the cheapest honest answer.
    ///
    /// The pool answers for the WATCHED surface, so this works on a page that
    /// joined its clip from a grid tile, which is every post opened from a card.
    func startPlayheadFeed() {
        publishPlayhead()
        guard playheadLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(publishPlayhead))
        // Thirty is smooth for a bar this size and half the work of sixty; the
        // range lets the system drop it further when the display does.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        playheadLink = link
    }

    /// ⚠️ `CADisplayLink` RETAINS ITS TARGET. A feed that stopped without
    /// invalidating would go on ticking inside a reuse pool for the life of
    /// the app, holding its target alive — so every exit from the feeding
    /// state comes through here.
    func stopPlayheadFeed() {
        playheadLink?.invalidate()
        playheadLink = nil
        onPlayhead?(nil, 0)
    }

    /// Whether the display link is running — for tests.
    var isFeedingPlayhead: Bool { playheadLink != nil }

    private var playheadLink: CADisplayLink?

    #if DEBUG
    private var lastPlayheadTrace: CFTimeInterval = 0
    #endif

    @objc private func publishPlayhead() {
        // The page this feeds is gone (the link holds this object, not the
        // cell): nothing is left to draw into, so the beat stops.
        guard let view = surface() else {
            playheadLink?.invalidate()
            playheadLink = nil
            return
        }
        let head = pool?.playhead(in: view)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-media-log") {
            // ⚠️ ONCE A SECOND, not thirty times: a trace that costs more than
            // the thing it watches changes what it is watching. The fraction
            // and the length together, because a nil here has two causes — no
            // player at all, and a length not known yet — and only the second
            // is normal.
            let now = CACurrentMediaTime()
            if now - lastPlayheadTrace > 1 {
                lastPlayheadTrace = now
                print(String(format: "[page-play] %.3f playhead=%@ seconds=%@ page=%d",
                             now,
                             head.map { String(format: "%.3f", $0.fraction) } ?? "nil",
                             head.map { String(format: "%.1f", $0.seconds) } ?? "nil",
                             debugCurrentPage()))
            }
        }
        #endif
        onPlayhead?(head?.fraction, head?.seconds ?? 0)
    }

    // MARK: - The scrub preview

    /// Fetches the frame the scrub card is pointing at, at a rate a decoder can
    /// actually keep.
    ///
    /// ⚠️ ONE IN FLIGHT, PLUS THE LATEST ASKED FOR. A thumb asks sixty times a
    /// second and a frame takes longer than that to decode, so requests issued
    /// per event would queue behind each other and the card would show where
    /// the thumb WAS, further behind with every point of travel. One request at
    /// a time, and when it lands, the most recent position is fetched if it has
    /// moved — which converges on the thumb instead of trailing it.
    func updateScrubPreview(_ fraction: Double?) {
        guard let fraction else {
            wantedPreviewFraction = nil
            onScrubPreviewLoading?(false)
            return
        }
        wantedPreviewFraction = fraction
        guard !isFetchingPreview else { return }
        fetchScrubPreview()
    }

    private func fetchScrubPreview() {
        guard let fraction = wantedPreviewFraction, let pool, let view = surface() else { return }
        isFetchingPreview = true
        onScrubPreviewLoading?(true)
        Task { [weak self] in
            let image = await pool.previewFrame(
                atFraction: fraction, in: view,
                maximumWidth: SnapScrubPreviewView.frameSize.width
            )
            guard let self else { return }
            isFetchingPreview = false
            // The gesture may have ended while this was decoding; the card is
            // already gone and its picture must not come back.
            guard let wanted = wantedPreviewFraction else { return }
            // ⚠️ A FAILED DECODE CHANGES NOTHING ON SCREEN. The card keeps the
            // last frame it had — the thumb has moved a little, not somewhere
            // else — and only says it is waiting while there is genuinely
            // nothing to show.
            if let image { onScrubPreviewPicture?(image) }
            if abs(wanted - fraction) > 0.001 {
                fetchScrubPreview()
            } else {
                onScrubPreviewLoading?(false)
            }
        }
    }

    private var wantedPreviewFraction: Double?
    private var isFetchingPreview = false

    // MARK: - Scrubbing the playhead

    /// How far from the asked-for moment a scrub's seek may land. Zero: frame
    /// accurate — see `seek(toFraction:)` for why a tolerant seek is what
    /// made the picture jump. `-scrub-tolerance <seconds>` overrides it in a
    /// debug build, for the A/B.
    static let scrubSeekTolerance: Double = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-scrub-tolerance"),
           position + 1 < arguments.count, let seconds = Double(arguments[position + 1]) {
            return seconds
        }
        #endif
        return 0
    }()

    /// The bar asked for a moment of the clip — a drag or a tap on it.
    func seek(toFraction fraction: Double) {
        guard let pool, let view = surface() else { return }
        // ⚠️ EXACT, drag or tap. The quarter-second tolerance this used to
        // take let the player answer with whichever frame it had nearest —
        // usually a keyframe — so the picture jumped between keyframes
        // while the thumb moved smoothly: "it skips a lot of frames". The
        // controller's chase keeps ONE seek in flight and goes to the
        // latest position when it lands, so exact seeks never queue up
        // behind the finger; they just land as fast as the decoder can.
        // Measured in the PR (`-scrub-log`).
        pool.seek(toFraction: fraction, in: view,
                  toleranceSeconds: Self.scrubSeekTolerance)
        #if DEBUG
        scrubTrace?.requests += 1
        #endif
        // The bar draws the finger itself while it drags (see
        // `SnapMediaPageBarView.heldPlayhead`); the fed playhead takes over
        // once the player has caught up.
    }

    /// Whether the clip was running when a drag took its playhead, so the
    /// release knows to start it again — and leaves a clip the viewer had
    /// paused, paused.
    private var resumesAfterScrub = false

    /// A recycled page owes no resume to the drag of the post it showed.
    func cancelScrubResume() {
        resumesAfterScrub = false
    }

    /// ⚠️ THE CLIP STOPS UNDER THE THUMB. Left running, it advanced between
    /// seeks and every landing was followed by a few frames of playback the
    /// finger never asked for — the picture shuffling forward and back while
    /// the thumb moved one way.
    func beginScrub() {
        guard let pool, let view = surface() else { return }
        resumesAfterScrub = pool.isPaused(in: view) == false
        pool.setPaused(true, in: view)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-scrub-log") {
            scrubTrace = ScrubTrace(start: CACurrentMediaTime(),
                                    landedAtStart: pool.debugSeeksLanded,
                                    cancelledAtStart: pool.debugSeeksCancelled)
        }
        #endif
    }

    /// Lands exactly where the thumb let go, and only THEN starts the clip
    /// again — see `VideoPlaybackController.whenSeeksSettle` for what resuming
    /// under a seek still in flight looked like.
    func endScrub(at fraction: Double?) {
        guard let pool, let view = surface() else { return }
        if let fraction {
            pool.seek(toFraction: fraction, in: view, toleranceSeconds: 0)
        }
        let resumes = resumesAfterScrub
        resumesAfterScrub = false
        #if DEBUG
        let trace = scrubTrace
        scrubTrace = nil
        #endif
        pool.whenSeeksSettle(in: view) { [weak self] in
            guard let self else { return }
            #if DEBUG
            if let trace {
                let seconds = CACurrentMediaTime() - trace.start
                let landed = pool.debugSeeksLanded - trace.landedAtStart
                print(String(format: "[scrub] %.3f %.2fs requests=%d landed=%d (%.1f/s) cancelled=%d "
                             + "tolerance=%.3fs head=%@",
                             CACurrentMediaTime(), seconds, trace.requests, landed,
                             Double(landed) / max(seconds, 0.001),
                             pool.debugSeeksCancelled - trace.cancelledAtStart,
                             Self.scrubSeekTolerance,
                             pool.playhead(in: view).map { String(format: "%.4f", $0.fraction) } ?? "nil"))
            }
            #endif
            // A page that stopped being watched mid-scrub stays stopped.
            guard resumes, self.isActive(), self.surface() === view else { return }
            pool.setPaused(false, in: view)
        }
    }

    #if DEBUG
    /// `-scrub-log`: what one drag asked of the player and what it got.
    private struct ScrubTrace {
        let start: CFTimeInterval
        let landedAtStart: Int
        let cancelledAtStart: Int
        var requests = 0
    }
    private var scrubTrace: ScrubTrace?
    #endif
}
