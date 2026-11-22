import CoreModels
import LaunchArguments
import MediaPlayback
import PostGrid
import QuartzCore
import UIKit

/// What a carousel's playback asks of its page (#2521): the media card that
/// holds the pages' surfaces, the pool, whether the page is the active one,
/// available and not deferring to a flight, the clip and scope it plays, and
/// the stopped mark on the picture.
@MainActor
protocol SnapCarouselPlaybackHost: AnyObject {
    var mediaCard: SnapMediaCardView { get }
    var videoPlayback: VideoPlaybackController? { get }
    var isActive: Bool { get }
    var isPostUnavailable: Bool { get }
    var defersPlaybackForFlight: Bool { get }
    var activeVideoURL: URL? { get }
    var playbackScope: String? { get }
    var representedPostID: PostID? { get }
    func setPauseGlyphVisible(_ visible: Bool)
}

/// A carousel post's playback on the full-screen page, out of `SnapFeedCell`
/// (#2521): the page reconcile (a clip starts when its page arrives, pauses
/// when it leaves), the retention window over the pool's capacity, the
/// warm-ups one swipe ahead, the release of the kept neighbours, and the
/// audit and probe the carousel suites read.
///
/// ⚠️ ORDER IS CORRECTNESS (#857): starting, warming and releasing move
/// players and pool loans between the page, a hero flight's card and the
/// grid tile. Each sequence moved here whole, in its order; a single
/// attachment's start and the flight's handoff stay with the page.
@MainActor
final class SnapCarouselPlayback {
    private unowned let host: any SnapCarouselPlaybackHost

    init(host: any SnapCarouselPlaybackHost) {
        self.host = host
    }

    // The page's state, read where the cell's code read it.
    private var mediaCard: SnapMediaCardView { host.mediaCard }
    private var videoPlayback: VideoPlaybackController? { host.videoPlayback }
    private var isActive: Bool { host.isActive }
    private var isPostUnavailable: Bool { host.isPostUnavailable }
    private var defersPlaybackForFlight: Bool { host.defersPlaybackForFlight }
    private var activeVideoURL: URL? { host.activeVideoURL }
    private var playbackScope: String? { host.playbackScope }
    private var representedID: PostID? { host.representedPostID }
    private func setPauseGlyphVisible(_ visible: Bool) { host.setPauseGlyphVisible(visible) }

    /// Reconciles playback with the page the viewer is now on.
    ///
    /// This is the carousel's autoplay: a clip starts when its page arrives and
    /// stops when it leaves. Both halves matter and the second is the one that
    /// bites — a page scrolled away from is still on screen in a full-bleed
    /// carousel, so a video left running there plays beside the photograph the
    /// viewer moved to.
    func reconcilePagePlayback() {
        guard mediaCard.showsCollection, let videoPlayback else { return }
        reconcileRetainedClips()
        // ⚠️ THE ARRIVING PAGE'S MARK, and only its own. This page is about to
        // be started (or is already running), so the receipt for a stop the
        // viewer made on it is spent. The page being LEFT keeps its mark and
        // carries it off the screen — that is the whole of "the mark belongs
        // to the picture".
        setPauseGlyphVisible(false)
        // ⚠️ PAUSED IN PLACE, never stopped and evicted.
        //
        // Stopping released the player and took the surface off its page, which
        // put that page's thumbnail back — the clip appeared to be replaced by a
        // photograph the moment the viewer moved on, and coming back paid for a
        // fresh decode. Paused, the page keeps its last frame and returning is
        // free. The player is released when the page itself goes: `didResignActive`
        // and `prepareForReuse` both already stop it.
        guard isActive, !isPostUnavailable, let url = activeVideoURL else {
            #if DEBUG
            CarouselPlaybackAudit.trace("post setPaused true page=\(mediaCard.currentPage)")
            #endif
            videoPlayback.setPaused(true, in: mediaCard.renderView)
            // ⚠️ A STILL PAGE WARMS TOO — the case the probe caught.
            //
            // Warming hung only off the paths that START something, so a viewer
            // landing on a photograph warmed nothing at all and the clip two
            // pages away was still a cold decode when they got there. Which is
            // the whole complaint: the players should be in place whether or not
            // the viewer is on them.
            prewarmNeighbouringClips()
            return
        }
        // ⚠️ A FLIGHT OWNS THE START while it is in the air.
        //
        // `activate` defers to it deliberately — starting here attaches a NEWER
        // layer to the player the card is flying and blanks the card mid-flight
        // — and this path, arriving from `configure`, was not honouring the same
        // rule. The audit caught it as a page holding a hosted, visible surface
        // with no player behind it, three times in one run.
        //
        // `startDeferredPlayback` picks it up at the landing, which is the
        // handshake that keeps one player and one playhead.
        guard !defersPlaybackForFlight else { return }
        // ⚠️ Hosted is not the same as PLAYABLE, and the difference is a whole
        // dismissal.
        //
        // A page dismissed and reopened keeps its carousel — same pages, so it
        // is deliberately not rebuilt — and the surface is still hanging in the
        // clip's page from the previous visit. But `prepareForReuse` stopped the
        // player, and `showCollection` hid the surface. Resuming on the strength
        // of "it is hosted" therefore asked a player that no longer existed to
        // play, left the surface hidden, and showed the page's THUMBNAIL.
        // Reported as "the player is no longer in the post screen".
        //
        // `setPaused` already answers whether there was anything to resume. Two
        // states looked alike from outside and the return value is what tells
        // them apart, so it is read rather than discarded.
        // ⚠️ RE-POINTED FIRST, then asked — the order is the whole of the
        // resume.
        //
        // `renderView` names the WATCHED page's surface, so until this call it
        // is still the page the viewer just left. Asking "is it hosted here"
        // before re-pointing therefore asked about the wrong view, always
        // answered no, and every return to a kept clip re-played it from a cold
        // decode — the retention would have been paid for and never spent.
        mediaCard.hostRenderViewOnCurrentPage()
        let surface = mediaCard.renderView
        // And the question is asked of the POOL, not of the hosting. A surface
        // can be hanging on its page with no player behind it — a dismissed and
        // reopened post is exactly that — and only the pool can tell the two
        // apart. See `GridVideoPlaybackCoordinator.isPlaying` for the same rule
        // on the other surface.
        let wasHosted = videoPlayback.hasPlayer(in: surface)
        #if DEBUG
        if LaunchArgument.mediaLog.isPassed() {
            print(String(format: "[page-play] %.3f page=%d hosted=%@ url=%@",
                         CACurrentMediaTime(), mediaCard.currentPage,
                         wasHosted ? "Y" : "N",
                         activeVideoURL?.lastPathComponent ?? "nil"))
        }
        #endif
        if wasHosted, videoPlayback.setPaused(false, in: surface) {
            #if DEBUG
            if LaunchArgument.mediaLog.isPassed() {
                print(String(format: "[page-play] %.3f resumed", CACurrentMediaTime()))
            }
            auditPagePlayback()
            #endif
            // The resumed path warms too: arriving back at a kept clip is the
            // moment the NEXT one becomes reachable in a swipe.
            prewarmNeighbouringClips()
            return
        }
        // ⚠️ The page's own cover, and NOT nil — clearing it is what hid the
        // surface.
        //
        // `play` detaches before it attaches, and detaching hides a surface
        // that is visible and has no poster: the class does that so a cover
        // does not sit on screen through the whole buffering window. Handing it
        // nil first therefore created the exact condition that hides it, and
        // nothing un-hid it afterwards — the viewer got the page's thumbnail
        // with a live player behind it, which is the state the audit reports as
        // `hosted=Y drawable=N`.
        //
        // A single-video post never hit this because its poster is loaded at
        // configure. The collection path is now the same: poster first, and the
        // first decoded frame retires it.
        surface.setPoster(mediaCard.currentPageCover)
        let scope = playbackScope
        let peakBitRate = MediaPlaybackPolicy.peakBitRate
        Task { [weak self] in
            await videoPlayback.play(url, in: surface, peakBitRate: peakBitRate, scope: scope)
            self?.auditPagePlayback()
            // ⚠️ AFTER, and that ordering is the whole safety of this.
            //
            // Prewarming opens streams. Doing it alongside the watched clip's
            // start would put them in competition for bandwidth with the only
            // picture on screen — trading a delay the viewer might never meet
            // for a stutter in the one they are certainly looking at.
            self?.prewarmNeighbouringClips()
        }
    }

    /// Brings the clips within one swipe to their first frame, so arriving at
    /// them shows a picture instead of a thumbnail and a wait.
    ///
    /// The retention window makes the RETURN to a clip free; this is the other
    /// half, and the one the viewer meets first. Bounded harder than retention
    /// — see `CarouselRetentionWindow.prewarmDepth` for why the two numbers are
    /// deliberately not the same.
    /// Warm-ups in flight, so a page that goes away can call them off.
    private var prewarmTasks: [Task<Void, Never>] = []

    /// Ends every warm-up in flight. Called wherever playback is given back.
    func cancelPrewarming() {
        for task in prewarmTasks { task.cancel() }
        prewarmTasks.removeAll()
    }

    func prewarmNeighbouringClips() {
        guard let videoPlayback, mediaCard.showsCollection, isActive else { return }
        // Data saver on cellular: nothing loads ahead of the viewer (#409).
        guard MediaPlaybackPolicy.preloads else { return }
        guard !defersPlaybackForFlight else { return }
        prewarmTasks.removeAll { $0.isCancelled }
        let pages = CarouselRetentionWindow.pagesToPrewarm(
            videoPages: mediaCard.videoPageIndices,
            currentPage: mediaCard.currentPage,
            budget: max(0, videoPlayback.capacity - 1)
        )
        for page in pages {
            guard let url = mediaCard.videoURL(onPage: page) else { continue }
            let surface = mediaCard.prepareSurface(forPage: page)
            // Already warm: a clip kept from an earlier visit needs nothing, and
            // asking would restart a player that is holding a good frame.
            guard !videoPlayback.hasPlayer(in: surface) else { continue }
            // ⚠️ A WARM-UP THAT LANDS AFTER THE PAGE HAS GONE IS UNDONE.
            //
            // `prewarm` resolves a URL and binds a player, and both happen after
            // an await — so a viewer who scrolls away in the meantime left the
            // cell holding a decoder it acquired AFTER giving everything back.
            // Caught by the accumulation battery, which is precisely the leak it
            // exists to find: one player survived every open/close cycle.
            //
            // Cancellation alone would not do it. The pool's await is not
            // cooperative, so the binding can still happen; what makes this safe
            // is asking again on the other side of it.
            let scope = playbackScope
            let task = Task { [weak self] in
                await videoPlayback.prewarm(url, in: surface, scope: scope)
                guard let self, self.isActive else {
                    videoPlayback.stop(surface)
                    return
                }
                #if DEBUG
                // ⚠️ REPUBLISHED once the warm-up has actually landed.
                //
                // The probe was written where warming is REQUESTED, so it
                // reported the state before any of it had happened and went on
                // saying so for ever. Reading `players=1` off that and calling
                // the warming broken would have been believing a stale snapshot
                // — the same mistake as trusting a log nothing had written to.
                self.publishRetentionProbe(pool: videoPlayback)
                #endif
            }
            prewarmTasks.append(task)
        }
        #if DEBUG
        if CarouselPlaybackAudit.isEnabled {
            CarouselPlaybackAudit.trace("prewarm pages=\(pages)")
        }
        publishRetentionProbe(pool: videoPlayback)
        #endif
    }

    /// Decides which of a collection's clips keep their player while the viewer
    /// is on one page, and ends the rest.
    ///
    /// ## Retention is EARNED, never speculative
    ///
    /// A page gets a player when the viewer actually lands on it. Leaving pauses
    /// it in place — surface, last decoded frame and playhead all kept — so
    /// coming back costs nothing and looks like nothing happened. A clip the
    /// viewer has never reached is not started early: it would spend a decoder
    /// on a guess, and the poster it shows meanwhile is the same picture the
    /// viewer would see anyway.
    ///
    /// What this method does is the OTHER half — deciding when a paused clip has
    /// drifted far enough to stop being worth its player. `CarouselRetentionWindow`
    /// answers that against the pool's stated capacity, so a gallery of twenty
    /// clips holds the same number of players as a gallery of three.
    private func reconcileRetainedClips() {
        guard let videoPlayback, mediaCard.showsCollection else { return }
        // ⚠️ Never mid-flight. The window would drop the surface the flight is
        // carrying, or re-host a neighbour over the card in the air.
        guard !defersPlaybackForFlight else { return }
        // ⚠️ RE-POINTED BEFORE THE WINDOW IS APPLIED.
        //
        // `renderView` names the watched page's surface, and the window spares
        // it — so applying the window first meant sparing the page just left,
        // one clip beyond the budget, on every page change. Only for a clip
        // page: a still has nothing to watch, and minting it a surface here
        // would spend one on a photograph.
        if mediaCard.currentPageVideoURL != nil {
            mediaCard.hostRenderViewOnCurrentPage()
        }
        let keep = CarouselRetentionWindow.pagesToRetain(
            videoPages: mediaCard.videoPageIndices,
            currentPage: mediaCard.currentPage,
            capacity: videoPlayback.capacity
        )
        // The watched surface is spared only when there IS one — on a still page
        // the previous clip has no claim on the budget beyond the window's.
        let watched = mediaCard.currentPageVideoURL != nil ? mediaCard.renderView : nil
        for view in mediaCard.retainSurfaces(onPages: keep, sparing: watched) {
            // The card gave these up; the pool is told here, because the card
            // does not own playback.
            videoPlayback.stop(view)
        }
        // ⚠️ EVERY page but the watched one is paused, and this is the half that
        // re-pointing `renderView` quietly removed.
        //
        // While one surface walked from page to page, leaving a page took its
        // player with it and the clip stopped by construction. Now the clip
        // keeps its own surface — so nothing stops it, and in a full-bleed
        // carousel the page just left is still on screen: the viewer moves to a
        // photograph and a video goes on playing beside it. Pausing here is what
        // makes "keeps its last frame" true rather than "keeps running".
        for page in mediaCard.surfacedPages where page != mediaCard.currentPage {
            // Adaptive streams are held paused exactly like files. They were
            // briefly released here instead, on the theory that resuming one was
            // what produced the fast-forward — it was not; the frames were
            // stale, not the playback (see `VideoFrameSource`). Keeping the
            // distinction would have cost the instant return on precisely the
            // long clips that benefit from it most, to work around a fault that
            // is fixed.
            videoPlayback.setPaused(true, in: mediaCard.surface(forPage: page))
        }
        mediaCard.hostRetainedSurfaces()
        #if DEBUG
        if CarouselPlaybackAudit.isEnabled {
            CarouselPlaybackAudit.trace(
                "retain page=\(mediaCard.currentPage) keep=\(keep) "
                + "surfaced=\(mediaCard.surfacedPages) "
                + "players=\(videoPlayback.activePlayerCount)/\(videoPlayback.capacity)"
            )
        }
        publishRetentionProbe(pool: videoPlayback)
        #endif
    }

    #if DEBUG
    /// Publishes the retention state where a UI test can read it.
    ///
    /// ⚠️ A UI test drives REAL gestures and sees only the screen — and none of
    /// what this feature promises is visible in a screenshot. "The clip kept its
    /// player" and "the clip was decoded again" produce the same picture; the
    /// difference is a cut the eye catches and a still frame cannot.
    ///
    /// So the invariant is published as an accessibility identifier rather than
    /// inferred from pixels. It is the same reasoning as the audit's file sink:
    /// an assertion needs something that can be WRONG, and a screenshot of a
    /// carousel is not it.
    func publishRetentionProbe(pool: VideoPlaybackController) {
        mediaCard.isAccessibilityElement = true
        mediaCard.accessibilityIdentifier = [
            "carousel",
            "page=\(mediaCard.currentPage)",
            // Total pages as well as clip count: a caller walking the carousel
            // needs to know how far it goes, and the clips are not necessarily
            // the pages it starts on.
            "pages=\(mediaCard.pageCount)",
            "clips=\(mediaCard.videoPageIndices.count)",
            "kept=\(mediaCard.surfacedPages.count)",
            "players=\(pool.activePlayerCount)",
            "capacity=\(pool.capacity)",
        ].joined(separator: ";")
    }
    #endif

    /// The post page's half of the carousel audit.
    ///
    /// ⚠️ Asked AFTER the play resolves, not when it is requested. The failure
    /// this exists to catch is a surface that is hosted and hidden, or hosted
    /// with no player behind it — states that only exist once everything has
    /// finished claiming success.
    private func auditPagePlayback() {
        #if DEBUG
        // ⚠️ Not while a flight is in the air. The card is covering this page,
        // so what the surface is doing underneath is not what the viewer sees —
        // and the handoff deliberately leaves the page without a player for the
        // duration. Judging it here would report the mechanism as the fault.
        guard CarouselPlaybackAudit.isEnabled, mediaCard.showsCollection else { return }
        // ⚠️ The flight guard scopes the CHECK, not the whole audit.
        //
        // Written as an early return it silenced the only thing writing the
        // file, and a run with `defersPlaybackForFlight` stuck on produced no
        // output at all — which reads exactly like a clean run. Three
        // measurements were lost to that before the file's timestamp gave it
        // away.
        guard !defersPlaybackForFlight else {
            CarouselPlaybackAudit.report("post (in flight)")
            return
        }
        let surface = mediaCard.renderView
        let hasPlayer = videoPlayback?.hasPlayer(in: surface) ?? false
        let drawable = !surface.isHidden && surface.alpha > 0 && hasPlayer
        if !drawable {
            print(String(
                format: "[audit] post detail hidden=%@ alpha=%.2f player=%@ deferring=%@",
                surface.isHidden ? "Y" : "N", surface.alpha,
                hasPlayer ? "Y" : "N", defersPlaybackForFlight ? "Y" : "N"
            ))
        }
        CarouselPlaybackAudit.check(
            surface: "post", subject: representedID?.rawValue ?? "-",
            page: mediaCard.currentPage,
            playing: isActive, clip: activeVideoURL != nil,
            hosted: mediaCard.hostsRenderViewOnCurrentPage,
            drawable: drawable
        )
        // ⚠️ A running total, because a silent auditor and a broken one read the
        // same in a log. A passing run has to be able to say how much it looked
        // at, or "0 failures" means nothing.
        CarouselPlaybackAudit.report("post")
        // ⚠️ One asset, one player. Reported from here because the post is the
        // second claimant: the card holds a paused player for the same clip
        // while this page opens one of its own.
        for (url, count) in videoPlayback?.playerCountByURL ?? [:] where count > 1 {
            CarouselPlaybackAudit.reportDuplicate(url: url.lastPathComponent, players: count)
        }
        #endif
    }

    /// See `SnapCellLifecycle.releaseRetainedNeighbourClips`. Idempotent, and
    /// safe on a cell that never played: the card reports what it let go of,
    /// and a cell holding nothing reports nothing.
    func releaseRetainedNeighbourClips() {
        guard let videoPlayback else { return }
        cancelPrewarming()
        // `releaseRetainedSurfaces` spares the watched surface by construction,
        // which is the whole reason this is safe to call while a dismissal
        // flight is still in the air.
        for view in mediaCard.releaseRetainedSurfaces() {
            videoPlayback.stop(view)
        }
        #if DEBUG
        if CarouselPlaybackAudit.isEnabled {
            CarouselPlaybackAudit.trace(
                "depart released neighbours, players=\(videoPlayback.activePlayerCount)"
            )
        }
        #endif
    }
}
