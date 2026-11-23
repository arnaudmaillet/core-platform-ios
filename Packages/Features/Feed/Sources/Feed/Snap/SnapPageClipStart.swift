import CoreStorage
import DesignSystem
import LaunchArguments
import MediaPlayback
import QuartzCore
import UIKit

/// What a page's clip start asks of its page (#2521): its media card, chrome,
/// pool and playback, its carousel's warm-ups, its state (active, available,
/// a clip, the clip's URL and scope, the flight's deferral and hold), the
/// surface it plays on, the flight's resume point, and the flight's handoff
/// (its deferral and warm attach).
@MainActor
protocol SnapPageClipStartHost: AnyObject {
    var mediaCard: SnapMediaCardView { get }
    var chrome: SnapChromeView { get }
    var videoPlayback: VideoPlaybackController? { get }
    var playback: SnapCellPlayback { get }
    var carouselPlayback: SnapCarouselPlayback { get }
    var isActive: Bool { get }
    var isPostUnavailable: Bool { get }
    var playsVideo: Bool { get }
    var activeVideoURL: URL? { get }
    var playbackScope: String? { get }
    var defersPlaybackForFlight: Bool { get }
    var isChromeHeldForFlight: Bool { get }
    var audibleSurface: VideoRenderView? { get }
    var isClipAdvancing: Bool { get }
    var flightMediaStartTime: TimeInterval? { get set }
    var flightHandoff: SnapFlightHandoff { get }
    func setPauseGlyphVisible(_ visible: Bool)
}

/// A page's own clip, out of `SnapFeedCell` (#2521): the viewport door (a clip
/// starts when its page passes half the screen), the start or resume on
/// activation, the pause or stop on resignation, the playhead feed to the
/// strip, and "Don't Cover People" (#484) while it plays.
///
/// ⚠️ ORDER IS CORRECTNESS (#857): starting, warming and stopping move
/// players and pool loans between the page, a hero flight's card and the
/// grid tile. Each sequence moved here whole, in its order; the flight's
/// warm attach is `SnapFlightHandoff`'s, and this calls it where it did.
@MainActor
final class SnapPageClipStart {
    private unowned let host: any SnapPageClipStartHost

    init(host: any SnapPageClipStartHost) {
        self.host = host
    }

    // The page's state, read and written where the cell's code did.
    private var mediaCard: SnapMediaCardView { host.mediaCard }
    private var chrome: SnapChromeView { host.chrome }
    private var videoPlayback: VideoPlaybackController? { host.videoPlayback }
    private var playback: SnapCellPlayback { host.playback }
    private var carouselPlayback: SnapCarouselPlayback { host.carouselPlayback }
    private var isActive: Bool { host.isActive }
    private var isPostUnavailable: Bool { host.isPostUnavailable }
    private var playsVideo: Bool { host.playsVideo }
    private var activeVideoURL: URL? { host.activeVideoURL }
    private var playbackScope: String? { host.playbackScope }
    private var defersPlaybackForFlight: Bool { host.defersPlaybackForFlight }
    private var isChromeHeldForFlight: Bool { host.isChromeHeldForFlight }
    private var audibleSurface: VideoRenderView? { host.audibleSurface }
    private var isClipAdvancing: Bool { host.isClipAdvancing }
    private var hasDeferredPlayback: Bool {
        get { host.flightHandoff.hasDeferredPlayback }
        set { host.flightHandoff.hasDeferredPlayback = newValue }
    }
    private var flightMediaStartTime: TimeInterval? {
        get { host.flightMediaStartTime }
        set { host.flightMediaStartTime = newValue }
    }
    private func setPauseGlyphVisible(_ visible: Bool) { host.setPauseGlyphVisible(visible) }
    private func warmAttachForFlight(url: URL) { host.flightHandoff.warmAttachForFlight(url: url) }

    /// "Don't Cover People" (#484): segments this page's clip while it owns
    /// the screen, and masks the band where people are.
    private let personOcclusion = PersonOcclusionDriver()

    /// Starts or stops "Don't Cover People" for this page. Asked whenever the
    /// page's activity, its clip or a flight changes; what can change between
    /// those (a pause, the band emptying, power and heat) the driver asks on
    /// every beat (`occlusionDecision`).
    func refreshPersonOcclusion() {
        // Read from the store, not the band's cached appearance: the band
        // reads it when it starts streaming, which can come after this page
        // became active.
        guard isActive, playsVideo, !isPostUnavailable, !isChromeHeldForFlight, let surface = audibleSurface,
              MediaCommentPreferencesStore.standard.preferences.avoidsPeople
        else {
            personOcclusion.stop()
            return
        }
        personOcclusion.decide = { [weak self] in self?.occlusionDecision() ?? .clear }
        personOcclusion.run(surface: surface, band: chrome.commentSurfaces.personOcclusionTicker)
    }

    /// The gate, asked eight times a second while the driver runs.
    private func occlusionDecision() -> PersonOcclusionDriver.Decision {
        let process = ProcessInfo.processInfo
        let inputs = PersonOcclusionGate.Inputs(
            enabled: SnapCommentTickerView.avoidsPeople,
            bandShown: chrome.commentSurfaces.isPersonOcclusionBandShown,
            pageActive: isActive,
            playing: isClipAdvancing,
            inFlight: isChromeHeldForFlight,
            lowPowerMode: LowPowerMode.savesBattery,
            thermalState: process.thermalState
        )
        #if DEBUG
        if PersonOcclusionDriver.traces, !PersonOcclusionGate.isOpen(inputs) { print("[occlusion] gate \(inputs)") }
        #endif
        return PersonOcclusionDriver.decision(for: inputs)
    }

    /// Whether this page covers most of the screen right now.
    var ownsViewport = false

    /// ⚠️ THE PLAYBACK-ONLY DOOR, and the only thing that may open mid-drag.
    ///
    /// A clip starts when its page passes half the screen, not when the scroll
    /// stops — waiting for the settle means a spring's worth of still frame on
    /// a page the viewer is already reading. But the page is NOT active yet:
    /// activation re-points the chrome, warms a window, reconciles the resting
    /// interface and brings the settled page clear of the toolbar, and running
    /// that from a scroll callback moved the scroll under the finger. That is
    /// why this exists as its own entrance and touches nothing but the picture.
    ///
    /// Idempotent by construction, because both callers are: the settle
    /// activates the same page a drag already handed the screen to, and the
    /// start below resumes a hosted player rather than opening a second one.
    func setOwnsViewport(_ owns: Bool) {
        guard ownsViewport != owns else { return }
        ownsViewport = owns
        guard playsVideo, videoPlayback != nil else { return }
        if owns {
            startWatchedClip()
        } else if !isActive {
            // ⚠️ PAUSED, never stopped: stopping releases the player and takes
            // the surface off its page, which puts the poster back on a page
            // that is still half on screen. The release belongs to the page
            // going away entirely — `didEndDisplaying`.
            pausePlaybackInPlace()
        }
    }

    #if DEBUG
    /// The page's own account of the picture: it owns the screen and it has a
    /// clip to run. Read by `SnapViewportPlaybackSpecTests`, which has no
    /// decoder and so cannot ask whether frames actually advanced.
    var debugOwnsPlayback: Bool { ownsViewport && playsVideo }
    #endif

    /// Pauses the watched surface where it stands, keeping the player, the
    /// loan and the last frame.
    private func pausePlaybackInPlace() {
        guard let videoPlayback else { return }
        videoPlayback.setPaused(true, in: mediaCard.renderView)
    }

    /// Brings the watched page's clip to the screen: adopt-and-resume if a
    /// player is already hosted, otherwise start one.
    ///
    /// Shared by activation and by the viewport door above, so the two cannot
    /// drift into two different ideas of what "playing" means.
    private func startWatchedClip() {
        guard !isPostUnavailable, let url = activeVideoURL, let videoPlayback else { return }
        // ⚠️ THE GLYPH IS NOT A STICKER. It says "you stopped this", and this
        // door is the page starting the clip for a reason of its own — the
        // viewer came back to a page they had paused, and it is playing again.
        // Left up, the mark would sit over moving pictures and the next tap
        // would read inverted: it pauses a clip that already looks paused.
        setPauseGlyphVisible(false)
        // A hero card may be flying this post's player right now. Starting here
        // would attach a NEWER layer to the same player and blank the card
        // mid-flight, so the start waits for the flight to land.
        guard !defersPlaybackForFlight else {
            hasDeferredPlayback = true
            mediaCard.hostRenderViewOnCurrentPage()
            warmAttachForFlight(url: url)
            return
        }
        mediaCard.hostRenderViewOnCurrentPage()
        let view = mediaCard.renderView
        #if DEBUG
        if LaunchArgument.mediaLog.isPassed() {
            // WHICH DOOR, and whether anything was there already. The whole
            // claim of the half-screen start is a matter of ORDER — read
            // against `[fling] begin`/`[fling] settle`, a line with `owns=Y
            // active=N` is the clip starting mid-scroll.
            print(String(format: "[page-play] %.3f start owns=%@ active=%@ hosted=%@ url=%@",
                         CACurrentMediaTime(), ownsViewport ? "Y" : "N",
                         isActive ? "Y" : "N",
                         videoPlayback.hasPlayer(in: view) ? "Y" : "N",
                         url.lastPathComponent))
        }
        #endif
        // ⚠️ ASKED OF THE POOL, not of the hosting: a surface can hang on its
        // page with no player behind it. A hosted player is resumed in place —
        // which is what makes the settle after a half-screen start free.
        if videoPlayback.hasPlayer(in: view), videoPlayback.setPaused(false, in: view) {
            carouselPlayback.prewarmNeighbouringClips()
            return
        }
        let scope = playbackScope
        let peakBitRate = MediaPlaybackPolicy.peakBitRate
        if let start = flightMediaStartTime, let scope {
            flightMediaStartTime = nil
            videoPlayback.prepareStart(of: url, scope: scope, at: start)
        }
        Task { [weak self] in
            await videoPlayback.play(url, in: view, peakBitRate: peakBitRate, scope: scope)
            // ⚠️ ACTIVATION IS ITS OWN DOOR, and it bypasses the page reconcile
            // entirely — which is why warming hung off that reconcile alone did
            // nothing at all for the case that matters most: opening a post.
            self?.carouselPlayback.prewarmNeighbouringClips()
        }
    }


    /// The activation's clip (`SnapFeedCell.willBecomeActive`, after its gates).
    func startOnActivation() {
        // A COLLECTION asks its page, not the post. Everything below is the
        // same sequence either way — the flight deferral, the warm attach, the
        // start — because the surface it all works on is the same object.
        switch playsVideo {
        case true:
            // `videoPlayback` is not bound here any more: the start below owns
            // that, and the only use left on this path is the flight's warm.
            guard let url = activeVideoURL, videoPlayback != nil else { return }
            // A hero card may be flying this post's player right now. Starting
            // here would attach a NEWER layer to the same player and blank the
            // card mid-flight, so the start waits for the flight to land — see
            // `startDeferredPlayback`.
            #if DEBUG
            if LaunchArgument.zoomLiveLog.isPassed() {
                // The PAGE matters as much as the flag: a collection warms
                // `renderView`, and which surface that names is a function of
                // the page the card believes it is on.
                print(String(format: "[zoom-live] %.3f cell activate defers=%@ page=%d collection=%@ url=%@",
                             CACurrentMediaTime(), defersPlaybackForFlight ? "true" : "false",
                             mediaCard.currentPage,
                             mediaCard.showsCollection ? "Y" : "N",
                             url.lastPathComponent))
            }
            #endif
            guard !defersPlaybackForFlight else {
                hasDeferredPlayback = true
                // ⚠️ WHICH SURFACE, BEFORE WARMING IT — and the deferred path
                // is the one that forgot to ask.
                //
                // `renderView` names the WATCHED page's surface, and a
                // collection re-points it per page. The line below this guard
                // does that before playing; the deferred branch went straight
                // to warming, so on a second visit to the same post it warmed
                // the surface belonging to the page the viewer opened LAST
                // TIME. Everything downstream then agreed with it: the landing
                // saw a surface full of frames and handed over — to a page
                // whose own surface was never hosted, so its poster showed —
                // and the dismissal donated that same stale view, so the card
                // flew home carrying the PREVIOUS clip. Reported exactly:
                // "open clip A, then clip B; B arrives on the thumbnail and the
                // dismiss shows A".
                //
                // Re-pointing is not playback: it moves no player and steals no
                // render slot from the flying card, which is what this guard
                // exists to protect. It is a no-op for a single attachment,
                // which is why the fault was galleries-only.
                mediaCard.hostRenderViewOnCurrentPage()
                // Warm THIS page's own layer now, hidden, instead of waiting.
                // It has the whole flight to decode, so by landing it is ready
                // and the handoff is a visibility flip rather than a re-parent
                // — which is what resets `isReadyForDisplay`.
                warmAttachForFlight(url: url)
                return
            }
            // The same start the viewport door uses, so a page that began
            // playing at the halfway mark is RESUMED here rather than started
            // a second time.
            startWatchedClip()
        case false:
            // Nothing to start: a photo page's media is STATIC. The slow
            // zoom that used to prove activation here is gone (see
            // `SnapMediaCardView`), and video is the only kind with
            // motion of its own.
            //
            // But a collection opening on a photograph still has clips further
            // in, and they are exactly the ones a viewer meets cold. Nothing to
            // play here does not mean nothing to prepare.
            carouselPlayback.prewarmNeighbouringClips()
        }
    }

    /// The resignation's clip (`SnapFeedCell.didResignActive`, after its stand-downs).
    func stopOnResign(releasingPlayback: Bool) {
        // Video is the only kind with anything to stop: a photo page's media
        // is static, so resigning leaves it exactly as it was.
        carouselPlayback.cancelPrewarming()
        guard playsVideo, let videoPlayback else { return }
        // ⚠️ PAUSED unless the page is actually going away.
        //
        // This stopped unconditionally, which detaches the surface and hands
        // the player back — so every page change put the poster back on the
        // page just left, and returning to it paid for a fresh decode. Reported
        // as "the player is removed whenever I leave the post, and the thumbnail
        // appears, which makes a cut".
        //
        // A paused page keeps its surface, its frame and its playhead, and
        // coming back is free. The loan is released only when the cell scrolls
        // fully off — see `didEndDisplaying`, which is the caller that passes
        // true — so the number of retained players stays bounded by the cells
        // the feed keeps alive rather than by how far the viewer has scrolled.
        if releasingPlayback {
            // Kept, paused, when the feed's lookahead wants this clip (the
            // page just left, or the next one): a swipe back adopts it (#895).
            videoPlayback.stop(mediaCard.renderView, keepingLookahead: true)
            // ⚠️ The neighbours go too, and they are invisible from here.
            //
            // A retained clip's player is bound to a surface this method never
            // names, so stopping only the watched one left every kept neighbour
            // holding a decoder for a cell that had scrolled away — the leak the
            // whole bound exists to prevent, arriving by the one path that does
            // not go through the window.
            for view in mediaCard.releaseRetainedSurfaces() {
                videoPlayback.stop(view)
            }
        } else {
            videoPlayback.setPaused(true, in: mediaCard.renderView)
        }
    }

    /// Keeps the page strip's clip bar fed while there is one to feed: the
    /// page is active and the clip under the viewer is a video. The feed
    /// itself (a display link) is `SnapCellPlayback.startPlayheadFeed`.
    func updatePlayheadFeed() {
        let wanted = isActive && playsVideo && !isPostUnavailable
        defer { refreshPersonOcclusion() }
        guard wanted else {
            stopPlayheadFeed()
            return
        }
        // The same question, the same answer: the page on screen, watching a
        // clip. The card narrows it to a single fitted-blurred one.
        mediaCard.setLiveBackdropActive(true)
        playback.startPlayheadFeed()
    }

    /// Every exit from the feeding state comes through here — see
    /// `SnapCellPlayback.stopPlayheadFeed` for why that matters.
    func stopPlayheadFeed() {
        playback.stopPlayheadFeed()
        mediaCard.setLiveBackdropActive(false)
    }
}
