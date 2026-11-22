import LaunchArguments
import MediaCore
import MediaPlayback
import QuartzCore
import UIKit

/// What the flight handoff asks of its page (#2521): its media card and
/// pool, its state (active, available, a clip, the clip's URL and scope, the
/// post's media and its kind), and the media wait it re-asks.
@MainActor
protocol SnapFlightHandoffHost: AnyObject {
    var mediaCard: SnapMediaCardView { get }
    var videoPlayback: VideoPlaybackController? { get }
    var isActive: Bool { get }
    var isPostUnavailable: Bool { get }
    var playsVideo: Bool { get }
    var activeVideoURL: URL? { get }
    var playbackScope: String? { get }
    var mediaURL: URL? { get }
    var mediaKind: MediaKind { get }
    func refreshMediaLoader()
}

/// A hero flight's handoff of the page's clip, out of `SnapFeedCell` (#2521):
/// the warm attach while an opening flies, the reveal and the deferred start
/// at its landing, whether the page has a picture to land on, and, on the way
/// home, the park, the donated surface, its adoption at a landing or its
/// reclaim on a cancel, the mirror and the departure.
///
/// ⚠️ ORDER IS CORRECTNESS (#857): these move players and pool loans between
/// the page, a hero flight's card and the grid tile. Each sequence moved here
/// whole, in its order, and the zoom destination calls each one where it did,
/// through the page's one-line forwards.
///
/// Shared with the page: none of its multi-writer properties (`mediaCard.alpha`,
/// `contentView.backgroundColor`, `chrome.alpha`, `columnStage.alpha`). It
/// re-points and shows or hides `mediaCard.renderView`, as the cell's code did.
@MainActor
final class SnapFlightHandoff {
    private unowned let host: any SnapFlightHandoffHost

    init(host: any SnapFlightHandoffHost) {
        self.host = host
    }

    // The page's state, read where the cell's code read it.
    private var mediaCard: SnapMediaCardView { host.mediaCard }
    private var videoPlayback: VideoPlaybackController? { host.videoPlayback }
    private var isActive: Bool { host.isActive }
    private var isPostUnavailable: Bool { host.isPostUnavailable }
    private var playsVideo: Bool { host.playsVideo }
    private var activeVideoURL: URL? { host.activeVideoURL }
    private var playbackScope: String? { host.playbackScope }
    private var mediaURL: URL? { host.mediaURL }
    private var mediaKind: MediaKind { host.mediaKind }
    private func refreshMediaLoader() { host.refreshMediaLoader() }

    /// Set while a presenting hero flight is staging, so this page's first
    /// activation does not steal the render slot from the flying card.
    var defersPlaybackForFlight = false
    var hasDeferredPlayback = false
    private var isWarmAttached = false

    /// Attaches the page's own surface to the parked player and keeps it
    /// hidden, so it decodes during the flight instead of after it.
    func warmAttachForFlight(url: URL) {
        guard let videoPlayback else { return }
        let view = mediaCard.renderView
        #if DEBUG
        view.debugTracksFlight = true
        view.debugLabel = "page"
        #endif
        if VideoRenderFlags.usesSampleBufferLayer {
            // N-surface: joining costs the flying card nothing, so this page's
            // surface is live AND visible from the moment it exists. The whole
            // hidden-warm-up-then-reveal dance below is a workaround for one
            // player having one render slot, and it has nothing to work around
            // here — the card, the tile and this page all draw the same frames
            // at the same time.
            guard videoPlayback.attachSurface(view, to: url, scope: playbackScope) else { return }
            // The tile's thumbnail-rung cap is NOT lifted here, deliberately.
            // An uncap invites an ABR switch, a switch changes the decoded
            // buffer's dimensions, and the layer re-fits the new buffer into
            // its bounds in a single frame — a discrete crop/sharpness pop
            // that this timing aimed squarely at the flight. The lift happens
            // in `startDeferredPlayback`, at `zoomTransitionDidEnd`, so
            // switch points land on a resting page.
            view.revealOnFirstFrame()
            hasDeferredPlayback = false
            isWarmAttached = true
            return
        }
        view.isHidden = true
        guard videoPlayback.unparkPlayback(to: view, mediaURL: url) else { return }
        hasDeferredPlayback = false
        isWarmAttached = true
    }

    /// Reveals the warmed surface at landing. A visibility flip only — no
    /// re-parenting, so the layer never leaves the render tree.
    func revealWarmAttachedSurface() -> Bool {
        guard isWarmAttached else { return false }
        isWarmAttached = false
        defersPlaybackForFlight = false
        mediaCard.renderView.isHidden = false
        return true
    }

    /// Starts the playback that activation held back, once the flight is over.
    /// The pool hands back the player the card was flying — same item, same
    /// playhead — so the page continues rather than restarting.
    func startDeferredPlayback() {
        defersPlaybackForFlight = false
        guard isActive, !isPostUnavailable, let url = activeVideoURL, let videoPlayback else { return }
        // The flight is over: lift the tile's thumbnail-rung cap NOW, at
        // rest, whether playback was warm-attached or is about to start. The
        // lift used to ride the warm attach — flight staging — which invited
        // the ladder's next switch point (a one-frame dimension re-fit on the
        // layer) to land mid-flight.
        videoPlayback.setPeakBitRate(0, for: url, scope: playbackScope)
        guard hasDeferredPlayback else { return }
        hasDeferredPlayback = false
        let view = mediaCard.renderView
        // The warm attach at activation loses a race on cold opens: the
        // tile's own `play` is still resolving then, so there is no active
        // player to join and the attach silently fails. Falling straight to
        // `play` here minted a SECOND AVPlayer for the same asset — two
        // decoders on two clocks for the whole feed session, a dismissal
        // card primed from whichever of them a URL lookup happened to find
        // (the frame-0 jump at the start of a dismiss), and a landing that
        // restarted at zero. By landing time the tile's play has resolved,
        // so try the join again first — it is the very player the flight
        // card was flying, which is what makes this a continuation. Mint
        // only when there is genuinely nothing to join.
        if VideoRenderFlags.usesSampleBufferLayer, videoPlayback.attachSurface(view, to: url, scope: playbackScope) {
            view.revealOnFirstFrame()
            return
        }
        let scope = playbackScope
        let peakBitRate = MediaPlaybackPolicy.peakBitRate
        // ⚠️ NOT HELD WHEN AUTOPLAY IS OFF (#702). The full-screen post is the
        // one the viewer opened: it plays whatever Autoplay and Low Power Mode
        // say, which govern grids, rails and previews (#409 held it here
        // under the pause mark).
        Task {
            await videoPlayback.play(url, in: view, peakBitRate: peakBitRate, scope: scope)
        }
    }

    /// Whether this page's media area has something REAL on screen — the
    /// landing-side twin of the grid's `isLandingPlaybackReady`.
    ///
    /// The present landing reveals the feed and unmounts the flight card in
    /// one commit, and it used to do so on a DATA answer alone (the feed has
    /// posts). Measured on device as the run-2 black beat: card removed, feed
    /// revealed, and the page's media area compositing nothing yet. A video
    /// page answers for its surface OR its poster — a page that has not
    /// started playing but shows its poster is presentable; one with neither
    /// is the black the card must keep covering. Text pages have no media
    /// area and nothing to wait for.
    var isMediaContentRendering: Bool {
        guard mediaURL != nil else { return true }
        // ⚠️ A COLLECTION ANSWERS FOR THE PAGE IT IS LANDING ON, not for the
        // carousel — and the difference is a whole class of reported defect.
        //
        // Resting on a photograph, the landing is presentable the moment that
        // photograph is: asking the render surface would make the page wait on
        // a decode only one of its pages needs. That was the original rule, and
        // it is still the right one for a still page.
        //
        // Resting on a CLIP it is the opposite. The card in the air is carrying
        // live video — the tile's own player, mid-playback — and this answer is
        // what lets the animator drop it. Answered from the image alone, the
        // card is dropped the instant the page's POSTER is up, so a moving
        // picture is replaced by a still one at the end of every flight. It
        // reads as "the player does not attach", it happens ONLY to galleries
        // (a single-video page already waits, below), and it is at its most
        // brutal under `-rich-media`, where a clip's poster is deliberately an
        // unrelated photograph — the media appears to change entirely.
        //
        // The hold is bounded by the animator's `maximumHydrationHold`, so a
        // clip that never draws still lands; it just no longer hands over to a
        // still while it had something better to show.
        // ⚠️ HAS A FRAME, not "is compositing" — the difference is a deadlock.
        //
        // `isCompositingContent` also asks whether the surface is VISIBLE, and
        // during a flight this page is deliberately hidden: the card is
        // standing in for it. Gating the card's removal on visibility means the
        // page cannot show until the card leaves and the card cannot leave
        // until the page shows, so every gallery landing ran to the animator's
        // ceiling. Measured as `render[hidden=Y frames=18]` — eighteen decoded
        // frames, reported as "not rendering". What the hand-over needs is that
        // there is a PICTURE to hand over to.
        if mediaCard.showsCollection {
            return mediaCard.currentPageVideoURL == nil
                ? mediaCard.isImageReady
                : mediaCard.renderView.hasFrame
        }
        switch mediaKind {
        case .video:
            return mediaCard.renderView.isCompositingContent
        case .image:
            return mediaCard.isImageReady
        }
    }

    /// Detaches this page's player and parks it for the next play of the same
    /// asset — the grid tile a dismissal is flying home to.
    @discardableResult
    func parkPlayback() -> Bool {
        guard playsVideo, let videoPlayback else { return false }
        if VideoRenderFlags.usesSampleBufferLayer {
            // Parking would detach this page's surface and stop it drawing,
            // and under N-surface there is no reason to: the landing tile takes
            // the loan directly via `transferOwnership` when the card lands, so
            // the player stays owned — and rendering — right up to that moment.
            // Reported as handled so the caller does not fall back to a park.
            return true
        }
        return videoPlayback.parkPlayback(from: mediaCard.renderView)
    }

    /// Hands the page's already-rendering surface to a dismissal's flight card,
    /// parking the player behind it.
    ///
    /// The card then flies the layer that is mid-playback instead of a mirror,
    /// which is blank for ~70ms — the flash at the start of a back-tap. The
    /// page keeps the view in its hierarchy but hands rendering over; on a
    /// cancelled grab `reclaimDonatedPlayback` puts everything back.
    func donateLiveRenderView() -> VideoRenderView? {
        guard playsVideo, let videoPlayback else { return nil }
        if VideoRenderFlags.usesSampleBufferLayer {
            // Nothing is donated: the card gets a surface of its own on the
            // same playback, primed with the current frame, and this page keeps
            // rendering behind it. A cancelled grab therefore has nothing to
            // put back — see `reclaimDonatedPlayback`.
            //
            // ALONGSIDE this page's own surface, by identity — never by URL.
            // Two players can exist for one asset (the cold-open race), and a
            // URL lookup answers from dictionary order: the card could prime
            // from the other player's playhead, which is the frame-0 jump at
            // the start of a dismiss. The sibling is what the viewer is
            // watching, so the card provably flies the same frames.
            let card = VideoRenderView()
            // ⚠️ NO OPAQUE GROUND ON A FLIGHT CARD'S SURFACE. The card carries
            // the picture ladder underneath — cover, sheet, thumbnail — and a
            // black ground on the live rung turns the one frame where this
            // layer has nothing to show into a black screen. See
            // `VideoRenderView.paintsOpaqueGround`.
            card.paintsOpaqueGround = false
            #if DEBUG
            card.debugLabel = "card"
            card.debugTracksFlight = true
            #endif
            let attached = videoPlayback.attachSurface(card, alongsideSurface: mediaCard.renderView)
            #if DEBUG
            if LaunchArgument.zoomLiveLog.isPassed() {
                print(String(format: "[zoom-live] %.3f producer FEED donateLiveRenderView -> %@ %@",
                             CACurrentMediaTime(), attached ? "attached" : "REFUSED",
                             card.debugSurfaceState))
            }
            #endif
            guard attached else { return nil }
            return card
        }
        guard videoPlayback.parkPlayback(from: mediaCard.renderView, keepingSurfaceAttached: true)
        else { return nil }
        let view = mediaCard.renderView
        // Same rule as the row's donation: a carousel page has to be TOLD the
        // surface is gone, or it refuses to take the same one back at landing.
        mediaCard.releaseRenderViewFromPages()
        view.removeFromSuperview()
        // ⚠️ BACK TO FILL ON ITS WAY OUT. This very view is about to be a grid
        // tile's (the dismissal adopts it at the landing), and grids fill. The
        // flight lays it out at the picture's own aspect, where fit and fill
        // draw the same pixels, so the switch is invisible here and saves a
        // letterboxed clip in a mosaic later. A no-op when the page fills. (The
        // sample-buffer branch above donates a fresh view, which is born fill.)
        // Unconditional: whether THIS page fitted is the page's business, and
        // a grid wants fill either way. Its ground goes back on with it, if the
        // page took it off for a fitted clip's bands.
        view.videoGravity = .resizeAspectFill
        view.posterAspect = nil
        mediaCard.restoreGround(of: view)
        return view
    }

    /// Installs the flight card's live surface as this page's own, at landing.
    ///
    /// The view arrives already rendering the frame the card was showing, so
    /// the page has nothing to wait for. The parked player is claimed here too,
    /// which is what makes the deferred start unnecessary — there is no
    /// separate `play` to blank the screen.
    /// Whether a landing keeps this page's own surface instead of adopting the
    /// card's (#639): the card's has nothing to continue, and this page is
    /// already showing something. Pure, for tests.
    static func keepsOwnSurface(incomingHasFrame: Bool, ownIsShowing: Bool) -> Bool {
        !incomingHasFrame && ownIsShowing
    }

    func adoptLiveRenderView(_ view: VideoRenderView) {
        defersPlaybackForFlight = false
        // ⚠️ ASKED BEFORE THE SWAP, not after. A card can land carrying a
        // player this page's pool does not own — a map pin mirrors the MAPS
        // pool's preview, which the map retires the moment the feed shows. The
        // swap used to happen first, so the page showed that dead surface and
        // its own (playing) one was thrown away; the post opened from a live
        // pin sat blank until paged away and back. Refusing keeps the page's
        // own surface, which is already rendering or about to.
        if VideoRenderFlags.usesSampleBufferLayer, let videoPlayback,
           !videoPlayback.canAdoptSurface(view) {
            refreshMediaLoader()
            return
        }
        #if DEBUG
        if LaunchArgument.zoomLiveLog.isPassed() {
            print(String(format: "[landing-adopt] %.3f alpha=%.2f pres=%.2f hidden=%@ anims=%@ frames=%d",
                         CACurrentMediaTime(), view.alpha, view.layer.presentation()?.opacity ?? -1,
                         view.isHidden ? "Y" : "N", (view.layer.animationKeys() ?? []).joined(separator: ","),
                         view.enqueuedFrameCount))
        }
        #endif
        // ⚠️ A SURFACE WITH NO FRAME HANDS NOTHING OVER (#639). The landing
        // adopts the card's surface to continue the frame it was showing; a card
        // whose mirror never drew has no frame to continue. Swapped in anyway,
        // it replaced a page that was already showing its poster — the gate
        // opens on that poster — and the viewer got black and the spinner for
        // as long as the adopted surface took to draw (probed: `frames=0` at
        // the gate, 0.4 s of black filmed). The page keeps its own surface: it
        // is joined to the same player and draws the next frame itself.
        if Self.keepsOwnSurface(incomingHasFrame: view.isReadyForDisplay,
                                ownIsShowing: mediaCard.renderView.isCompositingContent) {
            #if DEBUG
            if LaunchArgument.zoomLiveLog.isPassed() {
                print(String(format: "[landing-adopt] %.3f refused: the card's surface has no frame, the page shows its own",
                             CACurrentMediaTime()))
            }
            #endif
            refreshMediaLoader()
            return
        }
        // Read BEFORE the restore: it is the surface the restore throws away,
        // and under N-surface it is the one holding this page's pool loan.
        let replaced = mediaCard.renderView
        mediaCard.restoreRenderView(view)
        // ⚠️ RE-ASKED, because the adopted surface's announcement is IN THE
        // PAST. It arrives already rendering — that is the point of adopting it
        // — so `onPictureAvailabilityChange` fired while the flight owned it and
        // will not fire again: the signal is an edge, and this page missed it.
        //
        // That is the second half of the filmed defect and the half that
        // re-pointing the closure alone does not fix. The flight carries the
        // live player, so the page defers its own playback; its own surface
        // therefore sits at zero frames while the 0.25s grace runs out and the
        // spinner goes up; then the landing hands over a surface that already
        // has a picture, and nothing ever re-decides. A cold open is exactly
        // when the landing loses that race — measured at 11 stuck runs in 19,
        // and 0 in 5 when the grace was widened to 3s so the re-check happened
        // to land after the adoption.
        refreshMediaLoader()
        guard let videoPlayback else { return }
        if VideoRenderFlags.usesSampleBufferLayer {
            // ⚠️ THE LOAN MOVES WITH THE SURFACE. Nothing is parked under
            // N-surface, so the unpark below claims nothing here — and the
            // adopted view arrives JOINED to the page's player, while the loan
            // stays filed under the view the restore just discarded. The pool
            // then retires that player at its next dead-surface sweep, under
            // this page and under any card a grab has joined to it: the
            // early-grab stall, a black page after the cancel, and a refused
            // second donation. See `VideoPlaybackController.adoptSurface`.
            videoPlayback.adoptSurface(view, replacing: replaced)
            return
        }
        guard let url = activeVideoURL else { return }
        videoPlayback.unparkPlayback(to: view, mediaURL: url)
    }

    /// Puts a donated surface back and un-parks its player — the abandoned
    /// dismissal. No-op when the park was already claimed.
    func reclaimDonatedPlayback(_ view: VideoRenderView) {
        if VideoRenderFlags.usesSampleBufferLayer {
            // This page never gave anything up, so there is nothing to restore
            // — the abandoned card's surface is simply released. That is the
            // whole of "cancel" under N-surface, and it cannot leave the page
            // blank because the page's own surface never stopped drawing.
            videoPlayback?.detachSurface(view)
            return
        }
        mediaCard.restoreRenderView(view)
        // Same reason as `adoptLiveRenderView`: the surface coming back is the
        // one that was drawing all along, and its announcement is behind us.
        refreshMediaLoader()
        guard let url = mediaURL, let videoPlayback else { return }
        videoPlayback.unparkPlayback(to: view, mediaURL: url)
    }

    /// Attaches this cell's video player (if one is active) onto `surface` as
    /// an additional render layer — same player, same clock — so a dismissal
    /// flight carries the live video instead of a frozen cover. Returns
    /// whether a mirror was actually made.
    func mirrorPlayback(to surface: VideoRenderView) -> Bool {
        guard playsVideo, let videoPlayback else { return false }
        return videoPlayback.mirror(from: mediaCard.renderView, to: surface)
    }

    /// Re-asserts this cell as its player's display surface after a mirror
    /// surface goes away (a cancelled flight) — with multiple layers on one
    /// player, only the most recently attached is guaranteed to display.
    func reclaimPlayback() {
        guard playsVideo, let videoPlayback else { return }
        videoPlayback.reclaim(mediaCard.renderView)
    }

    /// The page is leaving with the flight that ended
    /// (`SnapFeedViewController.zoomTransitionWillDepart`): nothing deferred
    /// will start on it, and the deferral is cleared so a later visit of the
    /// reused screen does not inherit it. Its surface is deliberately left as
    /// it is: a reused screen keeps its clip paused in place for the next
    /// opening of the same post, and the grid repairs its own player at the
    /// landing.
    func releasePlaybackForDeparture() {
        defersPlaybackForFlight = false
        hasDeferredPlayback = false
    }
}

extension SnapFeedCell: SnapFlightHandoffHost {}
