import MediaCore
import CoreModels
import DesignSystem
import MediaPlayback
import PostGrid
import UIKit

/// A full-screen snap cell: cover-fit media under a `SnapChromeView` overlay
/// (scrim, full-width caption). Text-only posts render as an empty shell —
/// black page, no caption/ticker — under the screen chrome, until their
/// dedicated layout exists.
///
/// It reuses `FeedItemDisplayModel` as-is — only the fields relevant to a
/// full-bleed page (`mediaURL`, `thumbnailURL`, caption) are read; author
/// identity is the navigation bar's concern, and the precomputed heights are
/// ignored because every cell is bounds-sized.
///
/// The cell plays no part in the hero transition's animation: the flight is a
/// self-contained card owned by the animator (carrying its own chrome replica),
/// and the whole feed is simply revealed at landing. Nothing mutates a live
/// cell mid-flight.
final class SnapFeedCell: UICollectionViewCell, SnapCellLifecycle {
    static let reuseIdentifier = "SnapFeedCell"

    /// The media component: the video/photo render surfaces, full-bleed in
    /// BOTH states. The cell drives playback into `mediaCard.renderView`
    /// and gates the drift; the card owns the surfaces' motion. Engaging
    /// the comments does not move it — it becomes the page's background,
    /// with the stream reading over it. Text posts leave it empty
    /// (surfaces hidden), so the black contentView shows through.
    private let mediaCard = SnapMediaCardView()
    /// The engaged screen's readability layer, directly over the media and
    /// directly under the stream: a plain black wash — no blur — so
    /// comments stay legible over live content while the post stays
    /// visibly the post. Inert and invisible at rest; it is the layer that
    /// replaced the opaque black container the comments used to sit on.
    private let mediaBackdrop = SnapMediaBackdropView()
    private let chrome = SnapChromeView()

    /// A large centred play glyph shown while the active video is user-paused.
    private let pauseGlyph = UIImageView()

    private var representedID: PostID?

    /// Which post this cell's playback belongs to, for the pool's sharing rule.
    ///
    /// ⚠️ Two posts carrying the same file are two playbacks. Sharing a player
    /// between them makes pausing one freeze the other — see `playingScope` in
    /// `VideoPlaybackController`. The card and this page sharing one is the case
    /// the rule exists FOR, and they agree here because they name the same post.
    private var playbackScope: String? { representedID?.rawValue }
    private var mediaURL: URL?
    private var mediaKind: MediaKind = .image

    /// The stream this page should be playing RIGHT NOW, nil for none.
    ///
    /// ⚠️ Every playback path used to ask `mediaKind == .video` and take
    /// `mediaURL`, and both answer for the post's HEAD attachment. A collection
    /// whose first page is a photograph is a `.photo` post — so a clip on page
    /// two was unreachable, and a post that DID lead with a clip would have
    /// played it behind every other page.
    ///
    /// Routing both questions through one property is what let the rest of this
    /// file stay as it is: the surface, the parking, the mirroring and the
    /// landing all still work on `mediaCard.renderView` by identity.
    private var activeVideoURL: URL? {
        if mediaCard.showsCollection { return mediaCard.currentPageVideoURL }
        return mediaKind == .video ? mediaURL : nil
    }

    /// Whether there is anything to play at all — the replacement for the
    /// `mediaKind == .video` gates.
    private var playsVideo: Bool { activeVideoURL != nil }

    /// Reconciles playback with the page the viewer is now on.
    ///
    /// This is the carousel's autoplay: a clip starts when its page arrives and
    /// stops when it leaves. Both halves matter and the second is the one that
    /// bites — a page scrolled away from is still on screen in a full-bleed
    /// carousel, so a video left running there plays beside the photograph the
    /// viewer moved to.
    private func reconcilePagePlayback() {
        guard mediaCard.showsCollection, let videoPlayback else { return }
        reconcileRetainedClips()
        setPauseGlyphVisible(false)
        // ⚠️ PAUSED IN PLACE, never stopped and evicted.
        //
        // Stopping released the player and took the surface off its page, which
        // put that page's thumbnail back — the clip appeared to be replaced by a
        // photograph the moment the viewer moved on, and coming back paid for a
        // fresh decode. Paused, the page keeps its last frame and returning is
        // free. The player is released when the page itself goes: `didResignActive`
        // and `prepareForReuse` both already stop it.
        guard isActive, let url = activeVideoURL else {
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
        if ProcessInfo.processInfo.arguments.contains("-media-log") {
            print(String(format: "[page-play] %.3f page=%d hosted=%@ url=%@",
                         CACurrentMediaTime(), mediaCard.currentPage,
                         wasHosted ? "Y" : "N",
                         activeVideoURL?.lastPathComponent ?? "nil"))
        }
        #endif
        if wasHosted, videoPlayback.setPaused(false, in: surface) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-media-log") {
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
        Task { [weak self] in
            await videoPlayback.play(url, in: surface, scope: scope)
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
    private func cancelPrewarming() {
        for task in prewarmTasks { task.cancel() }
        prewarmTasks.removeAll()
    }

    private func prewarmNeighbouringClips() {
        guard let videoPlayback, mediaCard.showsCollection, isActive else { return }
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
    private func publishRetentionProbe(pool: VideoPlaybackController) {
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
    private var videoPlayback: VideoPlaybackController?
    private var imageTasks: [Task<Void, Never>] = []
    private var isActive = false

    // MARK: Comments engagement

    /// The user asked for the comments surface (the empty-state pill today;
    /// more entry points later). Carries the represented post.
    var onRequestComments: ((PostID) -> Void)?
    /// The rail's boost anchor asked to spend `amount` points on the
    /// represented post. The owning VC answers through the wallet and calls
    /// back `playBoostConfirmation` / `playBoostDenied` — the cell holds no
    /// balance opinion of its own.
    var onRequestBoost: ((PostID, _ amount: Int) -> Void)?
    /// The anchor's menu asked to take back this post's session spend —
    /// the VC owns the tally and the refund.
    var onRequestBoostUndo: ((PostID) -> Void)?

    /// Boost feedback pass-throughs — the chrome owns the anchor and its
    /// theatre; the VC owns the wallet verdict that picks which one plays.
    func playBoostConfirmation(amount: Int) { chrome.playBoostConfirmation(amount: amount) }
    func playBoostDenied() { chrome.playBoostDenied() }
    func playBoostRefund(amount: Int) { chrome.playBoostRefund(amount: amount) }
    /// The viewer's cumulative spend on this post — the anchor's number
    /// face. Set at configure (from the wallet's ledger) and again after
    /// each confirmed spend; chrome reset returns it to 0 on reuse.
    func setBoostTotal(_ total: Int) { chrome.setBoostTotal(total) }
    /// The anchor's wallet context (affordability + undoable tally) —
    /// pushed at configure and on every wallet change.
    func setBoostContext(balance: Int, undoable: Int) {
        chrome.setBoostContext(balance: balance, undoable: undoable)
    }
    /// While engaged, a tap on the strip (the docked media / the page
    /// background) asks to expand back — the owning VC dismisses the panel.
    var onRequestCommentsClose: (() -> Void)?
    /// While engaged, a vertical swipe on the glass card drives the feed
    /// pager INTERACTIVELY — the strip-side mirror of the composer bar's
    /// page-swipe. The cell forwards each pan phase with the raw vertical
    /// translation and velocity; the host hand-moves `contentOffset` so the
    /// whole engaged layer (which rides inside this cell) follows the finger
    /// in real time, settling on release.
    var onRequestCommentsPageDrive: ((CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void)?
    /// Whether the cell is in the comments-engaged layout (media docked in
    /// the strip's slot, chrome faded out, caption re-homed beside the
    /// media). Pure layout state: playback is deliberately untouched.
    private(set) var isCommentsEngaged = false
    /// The frozen screen thresholds (`applyChromeInsets`) — also the strip's
    /// vertical datum, so the slot math shares the chrome's inset authority.
    private var frozenInsets: UIEdgeInsets = .zero
    /// The engaged state's comments region: a cell-owned container spanning
    /// the strip's bottom to the cell's bottom edge. The comments UI itself
    /// is NOT cell state — the feed VC installs a child controller's view
    /// via `installComments` on engage and reclaims it on disengage, so
    /// thread data, scroll position, and a half-typed reply never live in a
    /// recycled cell. Z-order: above the media (which vacates the region),
    /// below the chrome (the action rail floats over it).
    private let commentsContainer = SnapCommentsContainerView()
    private var commentsContainerConstraints: [NSLayoutConstraint] = []
    /// The engaged header's frost: a dissolving blur band across the top
    /// inset, so the nav chrome stays legible where comment rows glide
    /// under it. A SIBLING of the comments container, not a child, so it
    /// never rides the stream's transform.
    private let headerFrost = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.headerFrostMaskColors,
        maskLocations: SnapCommentsLayout.headerFrostMaskLocations
    )
    private var headerFrostConstraints: [NSLayoutConstraint] = []
    /// Remembers a visible pause glyph across an engagement (the glyph is
    /// centered on the full page and would float mid-strip while docked).
    private var pauseGlyphSuppressedByEngagement = false
    /// The glass card's interactive exit pan — the composer bar's
    /// finger-connected swipe, mirrored onto the ENTIRE top floating
    /// card (media tile, caption column, music line, metrics row: one
    /// object, one gesture). Attached to the CELL (not the content view)
    /// so the cell's own `gestureRecognizerShouldBegin` override is its
    /// begin-time gate, exactly the bar's mechanism.
    private let cardSwipeRecognizer = UIPanGestureRecognizer()

    /// The viewer paged this post's collection. The screen forwards it to
    /// whatever opened the feed, so the card behind can follow.
    var onMediaPageChanged: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        pauseGlyph.image = UIImage(systemName: "play.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold))
        pauseGlyph.tintColor = UIColor.white.withAlphaComponent(0.85)
        pauseGlyph.contentMode = .center
        pauseGlyph.isUserInteractionEnabled = false
        pauseGlyph.isHidden = true
        pauseGlyph.layer.shadowColor = UIColor.black.cgColor
        pauseGlyph.layer.shadowOpacity = 0.4
        pauseGlyph.layer.shadowRadius = 6
        pauseGlyph.layer.shadowOffset = .zero

        // Background tap toggles play/pause; the delegate rejects taps that
        // land on an interactive control (the chrome's shortcut rail).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
        tap.delegate = self
        contentView.addGestureRecognizer(tap)

        // Hold to pause: the clip stops while the finger is down and resumes
        // when it lifts.
        //
        // ⚠️ IT MUST NOT CANCEL THE TAP, and the two must not fight. A hold is
        // a tap that outstayed its welcome, so the recognizers overlap by
        // construction: `cancelsTouchesInView = false` keeps the rest of the
        // cell reachable, and the short duration is what separates "toggle" from
        // "hold" in the hand rather than in the code.
        //
        // Deliberately NOT a toggle. A hold has an end, and playback resumes at
        // it — which is why it reads as "look at this frame" rather than as a
        // second way to press pause. The pause glyph stays out of it for the
        // same reason: nothing was chosen, so nothing should be announced.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleMediaHold))
        hold.minimumPressDuration = Self.holdToPauseDuration
        hold.cancelsTouchesInView = false
        hold.delegate = self
        contentView.addGestureRecognizer(hold)

        // The glass card's swipe exit. TWO locks keep it strictly inside
        // the engagement lifecycle — this recognizer paralyzed the whole
        // feed when it had neither:
        // 1. DISABLED at rest (`setCommentsEngaged` is the one switch):
        //    a disabled pan cannot receive or claim touches, full stop —
        //    the pager-lock doctrine, applied to our own gesture. Without
        //    it the idle pan won every vertical drag from the pager (a
        //    subview's recognizer outranks the ancestor scroll's pan).
        // 2. DELEGATE-gated begin: the begin gate must live in the
        //    delegate callback, not only the UIView override — UIKit
        //    consults `gestureRecognizerShouldBegin` on the HIT-TESTED
        //    view, and feed touches hit deep subviews (media, chrome),
        //    so a cell-level override alone is unreliable as a gate.
        cardSwipeRecognizer.addTarget(self, action: #selector(handleCardSwipe))
        cardSwipeRecognizer.delegate = self
        cardSwipeRecognizer.isEnabled = false
        addGestureRecognizer(cardSwipeRecognizer)

        buildLayout()

        // The two halves of the collection readout meet here and nowhere else:
        // the card owns the pages, the chrome owns the indicator, and neither
        // reaches for the other.
        mediaCard.onPageChanged = { [weak self] page in
            guard let self else { return }
            self.chrome.setMediaPage(page)
            self.reconcilePagePlayback()
            self.onMediaPageChanged?(page)
        }
        chrome.onMediaPageRequested = { [weak self] page in
            // Teleport, for the reason the card's own indicator does: the
            // scrubbing finger is the clock, and a scroll animation would run a
            // second one against it.
            self?.mediaCard.setPage(page, animated: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        // Text-only posts' gradient page background lives inside the chrome
        // (shared with the hero flight's replica, so the landing swap can't
        // mismatch), not here. The media card hosts both render surfaces
        // full-bleed — in both states: it is the page at rest AND the
        // background of the engaged screen.
        mediaCard.pin(to: contentView)

        // The readability layer, directly over the media: inert until the
        // engagement materializes it, and never moved again (it covers the
        // whole cell in both states, it just isn't visible in one).
        mediaBackdrop.pin(to: contentView)

        // The header frost sits directly above the stream and below the
        // chrome: media → backdrop → stream → frost → chrome.
        // (Added after the container below.)
        // The comments region sits between the readability layer and the
        // chrome (whose rail floats over it). Constraints are minted at
        // install (they depend on the frozen insets). The comments stream:
        // FULL cell height, TRANSPARENT — its content rests below the card
        // via scroll inset and glides underneath it when scrolled, with the
        // post's own media visible behind every row. (This view was opaque
        // black until the background-media layout: that one colour was the
        // curtain that hid the post for the whole engagement.) No internal
        // header: the mutation itself says "comments".
        commentsContainer.backgroundColor = .clear
        // SQUARE and UNCLIPPED. A screen-matched corner was tried twice:
        // `containerConcentricRadius` resolves to ~0 for a view flush with
        // its container, and reading `UIScreen._displayCornerRadius` meant
        // private API for something that was visually inert anyway — the
        // container is transparent, so a radius only clips content, and no
        // content reaches those corners.
        headerFrost.isHidden = true
        headerFrost.translatesAutoresizingMaskIntoConstraints = false
        commentsContainer.isHidden = true
        commentsContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(commentsContainer)
        contentView.addSubview(headerFrost)

        chrome.pin(to: contentView)

        // Centred pause glyph (added last so it sits above the media/chrome).
        pauseGlyph.constrain(in: contentView) { parent in
            pauseGlyph.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            pauseGlyph.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
    }

    // MARK: - Comments engagement

    /// Installs the comments UI (a child controller's view, owned by the
    /// feed VC) into the region below the strip, settled and ready BEFORE
    /// the engagement animates: the container starts invisible with a
    /// small downward offset so the one spring block lifts it in with the
    /// rest of the mutation.
    func installComments(_ view: UIView) {
        commentsContainer.isHidden = false
        // Pure crossfade, no translation: the bottom band's geometry must
        // hold dead-still while the old footer and the composer swap.
        commentsContainer.alpha = 0
        NSLayoutConstraint.deactivate(commentsContainerConstraints)
        // FULL height: the stream spans the whole cell and slides under the
        // strip (the hosted scroll view rests its content below the strip
        // via inset — `setEngagedInsets` on the child).
        commentsContainerConstraints = [
            commentsContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            commentsContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            commentsContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            commentsContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(commentsContainerConstraints)
        // The header band spans EXACTLY its container — screen top to where
        // the stream's content begins — and ramps across all of it: opaque
        // at the screen's edge, fully clear at the container's inner edge.
        // Nothing spills past the chrome the band exists to serve.
        headerFrost.isHidden = false
        // The veil, on the pages where the blur alone cannot be seen.
        headerFrost.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: mediaURL != nil))
        NSLayoutConstraint.deactivate(headerFrostConstraints)
        headerFrostConstraints = [
            headerFrost.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerFrost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerFrost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerFrost.heightAnchor.constraint(
                equalToConstant: SnapCommentsLayout.commentsTopInset(topInset: frozenInsets.top)
            ),
        ]
        NSLayoutConstraint.activate(headerFrostConstraints)
        // NOTE: no caption card is installed here. The caption is the
        // hosted stream's FIRST ROW now, so it scrolls with the comments
        // instead of floating above them — which is what removed the
        // measured caption height, the reserved strip rectangle, and the
        // job of keeping a fixed card in sync with a moving list.
        // NOTE: the media card is NOT z-lifted here. It stays at the back
        // of the stack for the whole engagement — the stream reads over it
        // through the backdrop, which is the entire point of this layout.
        // (It used to be raised above the frost so the docked tile could
        // float over the comments; that lift is what made its invisible
        // full-bleed frame eat stream touches, and it is gone with the
        // tile.)
        view.translatesAutoresizingMaskIntoConstraints = false
        commentsContainer.addSubview(view)
        view.pin(to: commentsContainer)
        contentView.layoutIfNeeded()
    }

    /// The engagement, driven by Core Animation.
    ///
    /// Four opacities move, and after the chrome's own collapse each is ONE
    /// layer: the comments container, the header band, the readability wash,
    /// and the page chrome. Model values are set first and unanimated — so
    /// the settled state is right even if an animation is removed — then one
    /// explicit animation per layer carries the eye.
    ///
    /// `presentation()` is the start value, not the model: an engagement
    /// interrupted mid-flight continues from what is on screen rather than
    /// snapping back to where the last one began. That is the same property
    /// the interactive pull-down relies on, which is why both paths can share
    /// `setCommentsEngagementProgress` as their definition of the two ends.
    func animateCommentsEngaged(
        _ engaged: Bool, duration: TimeInterval, completion: (() -> Void)? = nil
    ) {
        guard engaged != isCommentsEngaged else { return completion?() ?? () }
        let layers = engagementFadeLayers
        let starts = layers.map { ($0.presentation() ?? $0).opacity }
        UIView.performWithoutAnimation { setCommentsEngaged(engaged) }
        // The completion rides ONE designated layer, chosen by identity
        // rather than by position in the list: the comments container exists
        // for the cell's whole life and is always part of this transition, and
        // an ordinal would silently move if the list were ever reordered.
        let completionLayer = commentsContainer.layer
        for (layer, start) in zip(layers, starts) {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = start
            animation.toValue = layer.opacity
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // The completion hangs off ONE animation's delegate, not off the
            // transaction.
            //
            // `CATransaction.setCompletionBlock` is the obvious place for it
            // and it DOES NOT FIRE here — `performWithoutAnimation` above
            // opens and commits a nested transaction, and the block set on the
            // outer one never ran. That cost a real regression: the disengage's
            // teardown is what clears `commentsEngagedID`, and while it is set
            // `presentComments` refuses to open, so closing with the ✕ left
            // every comment entry point dead. A delegate is attached to the
            // animation itself and cannot be lost that way.
            if layer === completionLayer, let completion {
                animation.delegate = CALayerAnimationCompletion(completion)
            }
            layer.add(animation, forKey: "comments-engage-opacity")
        }
    }

    /// The four layers the engagement fades, in no particular order.
    private var engagementFadeLayers: [CALayer] {
        [commentsContainer.layer, headerFrost.layer, mediaBackdrop.layer, chrome.layer]
    }

    /// A still of the engaged thread, for a flight to carry over the media.
    ///
    /// ⚠️ THE STREAM ONLY — never the media under it. The flying card already
    /// carries the photograph, and on a video post it carries the LIVE surface;
    /// a still copy laid over that would freeze the one thing the flight works
    /// hardest to keep moving.
    ///
    /// `afterScreenUpdates: true` on purpose, and it is doing two jobs. The
    /// obvious one is that a page engaged before the push has never rendered,
    /// so a snapshot of what is already on screen would be blank. The other is
    /// that forcing the update here forces it HERE — inside the flight's
    /// staging, where the card is about to cover everything — rather than
    /// leaving it to the landing.
    func engagedCommentsSnapshot() -> UIView? {
        guard isCommentsEngaged, !commentsContainer.isHidden, commentsContainer.alpha > 0
        else { return nil }
        // ⚠️ THE WHOLE ENGAGED FACE MINUS THE MEDIA, not the stream alone.
        //
        // The stream by itself flew over an undimmed photograph and the landing
        // put the readability wash on in one frame: the page visibly darkened
        // the instant the card was removed, which is the same swap this is
        // meant to remove, in tone instead of in layout. The wash lives on
        // `mediaBackdrop`, a sibling of the stream, so the snapshot has to be
        // taken one level up — with the media itself hidden, because the card
        // is already carrying that and a still copy over a live surface is a
        // frozen video.
        //
        // Safe to hide it for the duration: `setZoomContentHidden(true)` has
        // already run by the time a flight asks for this, so nothing here is on
        // screen to flicker.
        let wasHidden = mediaCard.isHidden
        mediaCard.isHidden = true
        defer { mediaCard.isHidden = wasHidden }
        return contentView.snapshotView(afterScreenUpdates: true)
    }

    /// Materializes the header band's blur AHEAD of the engagement.
    ///
    /// A material arrives through `effect`, and building one is render-server
    /// work on the main thread — paid at engage it is part of the tap's frame
    /// budget. Paid on the warm it is free, and the band is invisible either
    /// way: its alpha is 0 in the dismissed pose, so a materialized-but-unseen
    /// blur costs nothing to composite (a fully transparent layer is not
    /// rendered).
    ///
    /// Window-guarded, like every glass surface here — headless CI never pays
    /// for a real blur — and idempotent, so the engagement's own attempt finds
    /// it already done.
    func prematerializeEngagedChrome() {
        guard window != nil, headerFrost.effect == nil, !headerFrost.isHidden else { return }
        headerFrost.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
    }

    /// The engaged stream's top inset — where its content rests, just
    /// below the screen chrome. A pure function of the safe area now: the
    /// caption scrolls inside the stream, so nothing above it has to be
    /// measured. The VC threads this into `setEngagedInsets`.
    func engagedCommentsTopInset(safeAreaTop: CGFloat) -> CGFloat {
        SnapCommentsLayout.commentsTopInset(topInset: safeAreaTop)
    }

    /// The engagement's INTERPOLATABLE state, as one function of progress:
    /// 0 = fully engaged, 1 = fully dismissed. Every leg that can be driven
    /// continuously lives here and nowhere else, which is what lets the
    /// finger-driven pull-down and the animated engage/disengage share one
    /// definition of what the two ends look like.
    ///
    /// (The blur bands and the bubble's glass are NOT here: a material
    /// materializes through the `effect` property, which has no fractional
    /// state. They switch at the ends and are hidden behind the fading
    /// stream while the drag is in flight.)
    func setCommentsEngagementProgress(_ progress: CGFloat) {
        let t = min(max(0, progress), 1)
        commentsContainer.alpha = 1 - t
        // NO transform here. The shrink belongs to the STREAM alone (the
        // hosted list scales itself), because the footer's blur band lives
        // inside this container and a band that scales stops sitting at the
        // screen's edge — it drifts inward and reads as part of the moving
        // layer instead of as fixed chrome.
        // The header band is a SIBLING, so it never scaled; it fades on its
        // own alpha to leave with everything else. (Alpha on an effect view
        // cannot MATERIALIZE a blur, which is why the band still switches
        // its `effect` at the ends — but fading an already-built one out is
        // exactly what alpha is for.)
        headerFrost.alpha = 1 - t
        mediaBackdrop.setDim(backdropDim(at: t))
        // The page's own chrome returns as the stream leaves — the ticker
        // and caption fade back IN as the comments fade out, one crossfade
        // rather than two sequential ones.
        chrome.setCommentsEngagedProgress(t)
    }

    /// The ground this page owns, remembered so a transition-scoped tint can
    /// be handed back without re-deriving the format.
    private var restingGround: UIColor = .systemBackground
    /// A ground borrowed for the length of a reveal — the gallery card's own
    /// fill, so the page the mask opens onto starts as the card the viewer
    /// tapped rather than as a lighter rectangle where the card used to be.
    ///
    /// Set through `setRevealGroundTint` and cleared by handing back `nil`.
    /// Applied to `contentView`, which is the surface `configure` paints, so
    /// there is exactly one writer of this colour and the resting value is
    /// never lost.
    private var revealGroundTint: UIColor?

    /// Wears `color` as the page's ground, or hands the page's own back.
    ///
    /// `backgroundColor` is animatable, so calling this inside an animation
    /// block CROSS-FADES — which is the whole mechanism: the card's fill at
    /// the handshake, the page's own by the landing, on the same spring as
    /// the mask. It also scrubs, so a dismissal driven by a finger carries the
    /// tint back at the speed of the hand.
    func setRevealGroundTint(_ color: UIColor?) {
        revealGroundTint = color
        contentView.backgroundColor = color ?? restingGround
    }

    /// The readability wash's opacity for THIS page at engagement progress
    /// `t` — the single answer both the interactive drive and the re-assert
    /// path must use, because the wash has two callers and they disagreed
    /// once already.
    ///
    /// The wash is a treatment FOR MEDIA and only media: it buys text
    /// contrast against an arbitrary photo. A text page has no photo to
    /// fight, and pouring 50% black over its own ground merely mutes it —
    /// invisible while that ground was black, a flat 50% grey the moment it
    /// started following the system appearance. (Measured exactly that:
    /// #7F7F7F over what should have been white.)
    private func backdropDim(at t: CGFloat) -> CGFloat {
        guard mediaURL != nil else { return 0 }
        return SnapCommentsLayout.backdropDimOpacity * (1 - t)
    }

    /// Reclaims the region after disengagement settles (the VC removes the
    /// child's view; this clears the cell-side scaffolding).
    func clearComments() {
        commentsContainer.subviews.forEach { $0.removeFromSuperview() }
        commentsContainer.isHidden = true
        NSLayoutConstraint.deactivate(commentsContainerConstraints)
        commentsContainerConstraints = []
        headerFrost.isHidden = true
        headerFrost.alpha = 1
        headerFrost.effect = nil
        NSLayoutConstraint.deactivate(headerFrostConstraints)
        headerFrostConstraints = []
        // The backdrop keeps its frame (it is pinned for the cell's life);
        // only its treatment is state. Reset it unconditionally so an
        // interrupted disengagement can't leave a recycled cell dimmed.
        mediaBackdrop.setActive(false)
    }

    /// Applies or reverses the comments-engaged layout. Call inside a
    /// single `UIView.animate` spring block — every mutation here is
    /// animatable (the backdrop's dim and blur, the media's recede, chrome
    /// surface alphas, the card's glass and content), which is what keeps
    /// the whole state change ONE motion on ONE surface. The player is
    /// untouched by construction: nothing here re-hosts it, and after the
    /// dock's removal nothing here even moves its surfaces.
    func setCommentsEngaged(_ engaged: Bool) {
        guard engaged != isCommentsEngaged else { return }
        isCommentsEngaged = engaged
        // The card's page-drive pan exists ONLY while engaged — the state
        // seam is the recognizer's power switch, so no teardown path can
        // strand an armed pan in the default feed. Armed on EVERY engaged
        // post (media AND text): a vertical swipe on the card drives the
        // pager interactively, exactly like the composer bar's — it pages,
        // it never dismisses, so it's the right gesture on a text post's
        // permanent resting interface too.
        cardSwipeRecognizer.isEnabled = engaged

        if engaged {
            if !pauseGlyph.isHidden {
                pauseGlyphSuppressedByEngagement = true
                pauseGlyph.isHidden = true
            }
            // THE BACKGROUND, not a tile: the media holds its full-bleed
            // frame, its identity transform, and its playback — the
            // engagement never touches it. Everything that DOES change is
            // one interpolatable set (see `setCommentsEngagementProgress`),
            // so the boolean legs and the finger-driven ones can never
            // diverge. (Near-inert on a text page: its media surfaces are
            // hidden and the readability wash is skipped entirely.)
            setCommentsEngagementProgress(0)
            // The band materializes on the same beat and the same supported
            // path (the `effect` property — alpha on an effect view is not,
            // which is also why the blur cannot ride the interactive drag).
            if window != nil, headerFrost.effect == nil {
                headerFrost.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
            }
        } else {
            setCommentsEngagementProgress(1)
            headerFrost.effect = nil
            if pauseGlyphSuppressedByEngagement {
                pauseGlyphSuppressedByEngagement = false
                pauseGlyph.isHidden = false
            }
        }
    }

    // MARK: - Configuration

    func configure(
        with model: FeedItemDisplayModel,
        pipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        initialMediaPage: Int? = nil
    ) {
        representedID = model.id
        mediaURL = model.mediaURL
        mediaKind = model.mediaKind
        self.videoPlayback = videoPlayback
        chrome.configure(with: model)
        chrome.setImagePipeline(pipeline)
        chrome.onCommentsTapped = { [weak self] in
            guard let self, let id = self.representedID, !self.isCommentsEngaged else { return }
            self.onRequestComments?(id)
        }
        chrome.onBoostRequested = { [weak self] amount in
            guard let self, let id = self.representedID else { return }
            self.onRequestBoost?(id, amount)
        }
        chrome.onBoostUndoRequested = { [weak self] in
            guard let self, let id = self.representedID else { return }
            self.onRequestBoostUndo?(id)
        }
        #if DEBUG
        // Which projection fields are present the moment the page is
        // configured. Everything listed here is supposed to render at 0ms from
        // the grid's own projection; anything reported missing is arriving on a
        // later fetch and is what "instant metadata" is actually waiting on.
        if ProcessInfo.processInfo.arguments.contains("-media-log") {
            print(String(format: "[media] %.3f page CONFIGURE author=%@ caption=%@ avatar=%@ audio=%@ likes=%@ age=%@",
                         CACurrentMediaTime(),
                         model.authorName.isEmpty ? "MISSING" : "yes",
                         model.caption?.isEmpty == false ? "yes" : "MISSING",
                         model.avatarURL == nil ? "MISSING" : "yes",
                         model.audioText?.isEmpty == false ? "yes" : "n/a",
                         model.likeCount > 0 ? "\(model.likeCount)" : "0",
                         model.timestampText.isEmpty ? "MISSING" : "yes"))
        }
        #endif
        let hasMedia = model.mediaURL != nil
        #if DEBUG
        // `-media-audit`: every page that configures WITHOUT a media payload,
        // and under `-rich-media` whether that is by design.
        //
        // The distinction this exists to draw: a text-only post rendering as a
        // coloured page is the product working, while a MEDIA post arriving
        // with no URL — or with one that never resolves — is a pipeline
        // failure, and the two are indistinguishable on screen. Both look like
        // "a solid colour where a photo should be".
        if ProcessInfo.processInfo.arguments.contains("-media-audit") {
            let rich = ProcessInfo.processInfo.arguments.contains("-rich-media")
            if !hasMedia {
                print("[media-audit] \(model.id.rawValue) NO MEDIA PAYLOAD"
                      + " kind=\(model.mediaKind) rich=\(rich)"
                      + " caption=\(model.caption?.isEmpty == false ? "yes" : "no")")
            } else {
                print(String(
                    format: "[media-audit] %.3f %@ media kind=%@ pages=%d url=%@",
                    CACurrentMediaTime(), model.id.rawValue, "\(model.mediaKind)",
                    model.mediaPages.count, model.mediaURL?.absoluteString ?? "-"
                ))
            }
        }
        #endif
        // THE PAGE'S GROUND. A media page is black because black is what
        // letterboxing should be — the surface exists to disappear behind a
        // photo. A TEXT page has nothing to disappear behind, so its ground
        // is the page itself and it follows the system appearance.
        restingGround = hasMedia ? .black : .systemBackground
        contentView.backgroundColor = revealGroundTint ?? restingGround
        // …and the page's THEME, applied once at the root of everything the
        // cell owns: the frost band, and the whole comment panel hosted
        // inside it. Both inherit from here rather than deciding for
        // themselves, which is what keeps them from disagreeing (see
        // `SnapChromeTheme`). The screen's bars live outside this tree and
        // are set from the same rule in `SnapFeedViewController`.
        contentView.overrideUserInterfaceStyle = SnapChromeTheme.style(hasMedia: hasMedia)
        // Composition is POSITIONAL now (the info card's frame is set at
        // install per `hasMedia`), so the info card itself is format-
        // agnostic — its caption always starts at its own inner padding.

        // The media card selects its surface for the kind and clears any
        // prior frame; a text post's surface simply never receives content.
        mediaCard.configure(kind: hasMedia ? model.mediaKind : .image)

        let isVideo = hasMedia && model.mediaKind == .video
        let isImage = hasMedia && model.mediaKind == .image

        // A COLLECTION replaces the single photo surface with its pages, and
        // returns before the single-media loads below: those fill a surface the
        // carousel has just hidden, and the work would be a download per page
        // that nothing draws.
        if model.isCollection {
            mediaCard.showCollection(model.mediaPages, imagePipeline: pipeline)
            // Without animation: this is where the page OPENS, not a move the
            // viewer made, and an animated jump would read as the carousel
            // scrolling by itself the moment the flight lands.
            // AFTER `showCollection`, and only when one was asked for: the
            // carousel keeps its page across a re-configure with the same pages,
            // so a second configure carrying no instruction must not be read as
            // an instruction to go back to the first.
            if let initialMediaPage { mediaCard.setPage(initialMediaPage, animated: false) }
            chrome.setMediaPageCount(model.mediaPages.count, current: mediaCard.currentPage)
            #if DEBUG
            // ⚠️ Published HERE as well as from the window, because the window
            // only runs once the page is active or the viewer has moved — so a
            // post sitting on page one, untouched, had no probe at all, and a UI
            // test read that absence as "no collection here". The state it
            // reports is the true one either way: nothing retained yet.
            if let videoPlayback { publishRetentionProbe(pool: videoPlayback) }
            #endif
            #if DEBUG
            // ⚠️ Both halves on one line: what was ASKED and where the carousel
            // ENDED UP. A sender that says nothing and a receiver that stays are
            // each behaving correctly on their own — the defect only exists
            // between them, so only a line that shows both can name it.
            if CarouselPlaybackAudit.isEnabled {
                print("[sync] post asked=\(initialMediaPage.map(String.init) ?? "-")"
                      + " landed=\(mediaCard.currentPage)")
            }
            #endif
            // ⚠️ Opening ON a clip is not a page CHANGE, so nothing above would
            // start it. A post opened from a card already showing page three
            // lands on page three; if that page is a video it has to play from
            // the moment it arrives, exactly as a single-video post does.
            if isActive { reconcilePagePlayback() }
            return
        }
        // A cell rebound from a collection to a single attachment without going
        // through reuse would otherwise keep the old post's clips alive behind
        // a hidden carousel.
        for view in mediaCard.releaseRetainedSurfaces() {
            videoPlayback?.stop(view)
        }
        mediaCard.hideCollection()
        chrome.setMediaPageCount(0, current: 0)

        if isImage {
            loadImage(model.mediaURL, expecting: model.id, pipeline: pipeline)
        }
        if isVideo, let thumbnailURL = model.thumbnailURL {
            loadPoster(thumbnailURL, expecting: model.id, pipeline: pipeline)
        }
    }

    /// Loads the video poster into the render view; shown under the player until
    /// the first frame is ready (or while an asset is still processing).
    private func loadPoster(_ url: URL, expecting id: PostID, pipeline: ImagePipeline) {
        // Cache hit applied SYNCHRONOUSLY — see `loadImage` for why the async
        // hop is what the viewer sees as a gap.
        if let cached = pipeline.cachedImage(for: url) {
            mediaCard.setPoster(cached)
            return
        }
        imageTasks.append(Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            self.mediaCard.setPoster(image)
        })
    }

    /// Freezes the chrome's layout bounds to the SCREEN's header/footer
    /// thresholds (the feed view's safe-area insets — nav bar bottom,
    /// toolbar top) instead of the cell's ambient safe area. Cells move
    /// during page transitions and ambient insets re-derive every frame;
    /// the pushed thresholds hold still, so the interaction zone (caption,
    /// ticker, subtitle, shortcut rail) rides the page with structurally
    /// accurate bounds. Same doctrine as the flight replica's captured
    /// insets — one chrome scaffold, one inset authority.
    func applyChromeInsets(_ insets: UIEdgeInsets) {
        frozenInsets = insets
        chrome.setFixedInsets(insets)
    }

    /// Hands the post's comment streams to the chrome's two surfaces (the
    /// band's queue, the subtitle zone's cues). Arrives from the view model
    /// whenever loaded — before or after this cell becomes visible; each
    /// surface starts once both its content and the visibility gate are in
    /// place.
    func updateCommentStreams(_ streams: FeedViewModel.CommentStreams) {
        #if DEBUG
        // The async half. `isLoaded=false` is the known-zero flag, so a first
        // delivery with it false is the placeholder and the real one follows.
        if ProcessInfo.processInfo.arguments.contains("-media-log") {
            print(String(format: "[media] %.3f page STREAMS loaded=%@ reactions=%d subtitles=%d count=%d",
                         CACurrentMediaTime(), streams.isLoaded ? "yes" : "NO",
                         streams.reactions.count, streams.subtitles.count, streams.commentCount))
        }
        #endif
        chrome.updateCommentStreams(streams)
        // The info card's comment metric rides the same seam (and the
        // same known-zero honesty flag) as the chrome's surfaces.
    }

    /// Visibility-scoped comment-surface control, driven by the view
    /// controller's `willDisplay`/`didEndDisplaying`: both surfaces render
    /// on any on-screen page, including one being dragged in, unlike
    /// playback which stays on the settle-quantized active seam.
    func setTickerStreaming(_ streaming: Bool) {
        chrome.setTickerActive(streaming)
        // The subtitle zone rides the same visibility seam: a page dragged
        // partway in slides in with its pill already rendered (the
        // persistent cue is static content between handoffs, like the
        // caption), instead of popping in after settle.
        chrome.setSubtitlesActive(streaming)
    }

    private func loadImage(_ url: URL?, expecting id: PostID, pipeline: ImagePipeline) {
        guard let url else { return }
        // A cache hit is applied SYNCHRONOUSLY, in the same turn as the
        // `configure` that just cleared the old image.
        //
        // This is the ~1200ms black window on image posts. `configure` nils the
        // image so a recycled cell can never show the previous post's photo —
        // which is correct — and every re-supply then went through a `Task`,
        // even when the image was already in memory. The card's black floor is
        // what filled that hop, and re-entering a post you had just been
        // looking at showed photo, black, the SAME photo.
        //
        // Deferring the nil-out instead would close the gap by showing the
        // OUTGOING post's photo on the incoming page — a wrong image rather
        // than no image, which in a paging feed is the worse failure. Reading
        // the cache first has neither: the correct photo, no gap. It is also
        // what `PostGridTileCell.configure` has always done; only the feed
        // went straight to the async path.
        //
        // A genuine cache miss still loads asynchronously and still shows the
        // floor. That is a first load with nothing to display yet, which is a
        // different thing from blanking something we already had.
        if let cached = pipeline.cachedImage(for: url) {
            mediaCard.setImage(cached)
            return
        }
        imageTasks.append(Task { [weak self] in
            let image: UIImage?
            do {
                image = try await pipeline.image(for: url)
            } catch {
                // A post that HAS a media URL and cannot load it leaves the
                // card on its floor — visually identical to a text page, and
                // silent until now. This is the failure the audit is for.
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-media-audit") {
                    print("[media-audit] \(id.rawValue) IMAGE LOAD FAILED"
                          + " url=\(url.absoluteString) error=\(error)")
                }
                #endif
                return
            }
            guard let image else { return }
            guard let self, self.representedID == id else { return }
            self.mediaCard.setImage(image)
        })
    }

    // MARK: - SnapCellLifecycle

    func willBecomeActive() {
        guard !isActive else { return }
        isActive = true
        // Activation always starts playing, so any user-paused glyph is stale.
        setPauseGlyphVisible(false)
        // Normally redundant with the visibility path (`setTickerStreaming`),
        // but it is the restart edge after backgrounding: foregrounding
        // re-activates the settled page without a fresh `willDisplay`.
        // Both comment surfaces share it.
        chrome.setTickerActive(true)
        chrome.setSubtitlesActive(true)
        // A COLLECTION asks its page, not the post. Everything below is the
        // same sequence either way — the flight deferral, the warm attach, the
        // start — because the surface it all works on is the same object.
        switch playsVideo {
        case true:
            guard let url = activeVideoURL, let videoPlayback else { return }
            // A hero card may be flying this post's player right now. Starting
            // here would attach a NEWER layer to the same player and blank the
            // card mid-flight, so the start waits for the flight to land — see
            // `startDeferredPlayback`.
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print(String(format: "[zoom-live] %.3f cell activate defers=%@",
                             CACurrentMediaTime(), defersPlaybackForFlight ? "true" : "false"))
            }
            #endif
            guard !defersPlaybackForFlight else {
                hasDeferredPlayback = true
                // Warm THIS page's own layer now, hidden, instead of waiting.
                // It has the whole flight to decode, so by landing it is ready
                // and the handoff is a visibility flip rather than a re-parent
                // — which is what resets `isReadyForDisplay`.
                warmAttachForFlight(url: url)
                return
            }
            mediaCard.hostRenderViewOnCurrentPage()
            let view = mediaCard.renderView
            let scope = playbackScope
            Task { [weak self] in
                await videoPlayback.play(url, in: view, scope: scope)
                // ⚠️ ACTIVATION IS ITS OWN DOOR, and it bypasses the page
                // reconcile entirely — which is why warming hung off that
                // reconcile alone did nothing at all for the case that matters
                // most: opening a post. The test read "page one was never
                // prepared", and it was right.
                self?.prewarmNeighbouringClips()
            }
        case false:
            // Nothing to start: a photo page's media is STATIC. The slow
            // zoom that used to prove activation here is gone (see
            // `SnapMediaCardView`), and video is the only kind with
            // motion of its own.
            //
            // But a collection opening on a photograph still has clips further
            // in, and they are exactly the ones a viewer meets cold. Nothing to
            // play here does not mean nothing to prepare.
            prewarmNeighbouringClips()
        }
    }

    /// Set while a presenting hero flight is staging, so this page's first
    /// activation does not steal the render slot from the flying card.
    var defersPlaybackForFlight = false
    private var hasDeferredPlayback = false
    private var isWarmAttached = false

    /// Attaches the page's own surface to the parked player and keeps it
    /// hidden, so it decodes during the flight instead of after it.
    private func warmAttachForFlight(url: URL) {
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
            guard videoPlayback.attachSurface(view, to: url) else { return }
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
        guard isActive, let url = activeVideoURL, let videoPlayback else { return }
        // The flight is over: lift the tile's thumbnail-rung cap NOW, at
        // rest, whether playback was warm-attached or is about to start. The
        // lift used to ride the warm attach — flight staging — which invited
        // the ladder's next switch point (a one-frame dimension re-fit on the
        // layer) to land mid-flight.
        videoPlayback.setPeakBitRate(0, for: url)
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
        if VideoRenderFlags.usesSampleBufferLayer, videoPlayback.attachSurface(view, to: url) {
            view.revealOnFirstFrame()
            return
        }
        let scope = playbackScope
        Task { await videoPlayback.play(url, in: view, scope: scope) }
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
        // ⚠️ A collection answers for its CAROUSEL even when the page it is on
        // is a clip: the pages either side are photographs, and the landing is
        // presentable the moment they are. Asking the render surface would make
        // the whole page wait on a decode that only one of its pages needs.
        if mediaCard.showsCollection { return mediaCard.isImageReady }
        switch mediaKind {
        case .video:
            return mediaCard.renderView.isCompositingContent
        case .image:
            return mediaCard.isImageReady
        }
    }


    #if DEBUG
    /// The media area's full state for the landing trace.
    var debugMediaState: String {
        "kind=\(mediaKind) url=\(mediaURL == nil ? "nil" : "set") render[\(mediaCard.renderView.debugSurfaceState)]"
    }
    #endif

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
            #if DEBUG
            card.debugLabel = "card"
            card.debugTracksFlight = true
            #endif
            let attached = videoPlayback.attachSurface(card, alongsideSurface: mediaCard.renderView)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
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
        return view
    }

    /// Installs the flight card's live surface as this page's own, at landing.
    ///
    /// The view arrives already rendering the frame the card was showing, so
    /// the page has nothing to wait for. The parked player is claimed here too,
    /// which is what makes the deferred start unnecessary — there is no
    /// separate `play` to blank the screen.
    func adoptLiveRenderView(_ view: VideoRenderView) {
        defersPlaybackForFlight = false
        mediaCard.restoreRenderView(view)
        guard let url = activeVideoURL, let videoPlayback else { return }
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
        guard let url = mediaURL, let videoPlayback else { return }
        videoPlayback.unparkPlayback(to: view, mediaURL: url)
    }

    // MARK: - Play/pause toggle

    /// Begin-time gate for the card's swipe exit, the composer bar's
    /// mechanism verbatim: engaged only, vertical intent only (the
    /// dominant velocity axis at begin time), and born anywhere inside
    /// the floating glass card's territory (slightly expanded for thumb
    /// forgiveness). Scoped to the card pan — every other recognizer
    /// keeps UIKit's default.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === cardSwipeRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard isCommentsEngaged else { return false }
        let velocity = cardSwipeRecognizer.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        return cardSwipeRegionContains(cardSwipeRecognizer.location(in: contentView))
    }

    /// The page-drive swipe's territory: the HEADER BAND — everything above
    /// where the stream's content begins.
    ///
    /// It used to be the floating caption card. With the caption scrolling
    /// as a list row there is no non-scrolling card left to grab, and the
    /// band above the stream is the only cell territory a drag can start in
    /// without fighting the list: below this line a vertical drag scrolls
    /// the comments, which is exactly what it should do. Internal (not
    /// private) so the boundary stays unit-testable.
    func cardSwipeRegionContains(_ point: CGPoint) -> Bool {
        guard point.y >= 0 else { return false }
        return point.y <= SnapCommentsLayout.commentsTopInset(topInset: frozenInsets.top)
    }

    /// A vertical swipe on the glass card drives the feed pager
    /// INTERACTIVELY (same as the composer bar's page-swipe). The whole
    /// engaged layer — docked media card, glass, comments — lives inside
    /// THIS cell, so once the host hand-moves the pager's `contentOffset`
    /// the entire assembly rides the finger for free; the cell only
    /// forwards the pan's phase + raw translation/velocity. No self-nudge
    /// (that would double the motion), no commit-only settle.
    @objc private func handleCardSwipe(_ pan: UIPanGestureRecognizer) {
        guard isCommentsEngaged else { return }
        let dy = pan.translation(in: self).y
        let vy = pan.velocity(in: self).y
        switch pan.state {
        case .began:
            onRequestCommentsPageDrive?(.began, 0, 0)
        case .changed:
            onRequestCommentsPageDrive?(.changed, dy, vy)
        case .ended, .cancelled, .failed:
            onRequestCommentsPageDrive?(.ended, dy, vy)
        default:
            break
        }
    }

    @objc private func handleBackgroundTap() {
        // While engaged, the strip is the only cell territory the panel
        // doesn't cover — a tap there means "expand back", not play/pause.
        // Unless the post is TEXT-ONLY: its engagement is the permanent
        // resting state, and no tap may collapse it onto the empty shell.
        if isCommentsEngaged {
            if mediaURL != nil { onRequestCommentsClose?() }
            return
        }
        togglePlayback()
    }

    /// How long a press must last before it counts as a hold rather than a tap.
    ///
    /// Short, because the gesture's whole value is that it feels immediate —
    /// hold to look, let go to carry on. Long enough that an ordinary tap on
    /// the way to play/pause never trips it.
    static let holdToPauseDuration: TimeInterval = 0.2

    /// Whether a hold is what stopped playback, so its end knows to resume.
    ///
    /// ⚠️ Recorded rather than assumed. A clip the viewer had ALREADY paused by
    /// tapping must not start playing because a later hold ended on it — the
    /// release undoes the hold, and nothing else.
    private var isHeldPaused = false

    @objc private func handleMediaHold(_ recognizer: UILongPressGestureRecognizer) {
        guard playsVideo, let videoPlayback else { return }
        switch recognizer.state {
        case .began:
            // Only a clip that is actually running can be held. Holding a
            // paused one and letting go would otherwise start it.
            guard videoPlayback.isAdvancing(in: mediaCard.renderView) else { return }
            isHeldPaused = videoPlayback.setPaused(true, in: mediaCard.renderView)
        case .ended, .cancelled, .failed:
            guard isHeldPaused else { return }
            isHeldPaused = false
            videoPlayback.setPaused(false, in: mediaCard.renderView)
        default:
            break
        }
    }

    /// Toggles the active video's playback and reflects it in the pause glyph.
    /// No-op for image/text cells (no player).
    func togglePlayback() {
        guard playsVideo, let videoPlayback else { return }
        let paused = videoPlayback.togglePlayback(in: mediaCard.renderView)
        setPauseGlyphVisible(paused)
    }

    private func setPauseGlyphVisible(_ visible: Bool) {
        guard pauseGlyph.isHidden == visible else { return }
        UIView.transition(with: pauseGlyph, duration: 0.15, options: .transitionCrossDissolve) {
            self.pauseGlyph.isHidden = !visible
        }
    }

    // MARK: - Hero-flight live media

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

    #if DEBUG
    /// The page's playback surface, for a test that needs to ask the pool about
    /// it. Playback ownership is the pool's, so a test has to name the surface.
    /// Holds the page's own chrome back while a flight's REPLICA stands in for
    /// it, then brings it in.
    ///
    /// ⚠️ The replica exists precisely so the real chrome need not be visible in
    /// the air. It was anyway — nothing ever hid it — so the card simply lifted
    /// off a fully drawn page, and at the landing the replica vanished and the
    /// real thing was revealed on one frame. That is the pop: not something
    /// appearing, but something that had been there all along stopping being
    /// covered.
    func setChromeHeldForFlight(_ held: Bool) {
        if held {
            chrome.alpha = 0
            return
        }
        guard chrome.alpha < 1 else { return }
        // ⚠️ NOT WHEN THE COMMENTS ALREADY OWN THE CHROME.
        //
        // `chrome` is one of the engagement's own fade layers: engaged, it is
        // deliberately at zero. This restore is unconditional — it exists to
        // undo the HOLD, and it wrote the same property — so a post opened
        // straight into its thread landed wearing both interfaces at once, the
        // ticker and the caption and the page dots sitting under a comment
        // stream.
        //
        // The hold's opposite is not "visible", it is "whatever the page was
        // doing before it was covered".
        guard !isCommentsEngaged else { return }
        UIView.animate(
            withDuration: 0.26, delay: 0.02,
            usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.chrome.alpha = 1
        }
    }

    /// The page indicator's scrub, so the screen can make its dismissal yield.
    var mediaScrubGesture: UIGestureRecognizer { chrome.mediaScrubGesture }

    var debugRenderSurface: VideoRenderView { mediaCard.renderView }

    /// Moves the collection to a page as a viewer's swipe would.
    ///
    /// The simulator injects no touches and a unit test has no gesture, so this
    /// is how the event this whole file turns on is reached. It goes through
    /// `setPage`, not around it — the page change must arrive by the same path
    /// a real swipe takes, or a test would be pinning a route nobody uses.
    func debugShowPage(_ index: Int) {
        mediaCard.setPage(index, animated: false)
    }

    /// Which pages are holding a playback surface — the retention window's
    /// footprint, which is otherwise invisible from outside.
    var debugSurfacedPages: [Int] { mediaCard.surfacedPages }

    /// The surface a given page is holding, so a test can ask the POOL what is
    /// behind it rather than trusting the cell's own account.
    func debugSurface(forPage page: Int) -> VideoRenderView {
        mediaCard.surface(forPage: page)
    }
    #endif

    func didResignActive(releasingPlayback: Bool) {
        guard isActive else { return }
        isActive = false
        // Covers the paths visibility can't see: backgrounding and the
        // feed's own disappearance, where no `didEndDisplaying` fires.
        chrome.setTickerActive(false)
        chrome.setSubtitlesActive(false)
        // Video is the only kind with anything to stop: a photo page's media
        // is static, so resigning leaves it exactly as it was.
        cancelPrewarming()
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
            videoPlayback.stop(mediaCard.renderView)
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

    /// Re-asserts the engaged treatment after the screen re-appears from an
    /// outbound push: the backdrop's blur is window-guarded, so an
    /// engagement that began off-window never materialized it. Layout runs
    /// first so the pass reads settled coordinates, not a mid-transition
    /// hierarchy. Idempotent — and it has nothing to say about the media,
    /// which holds identity in both states.
    func reassertEngagedGeometry() {
        guard isCommentsEngaged else { return }
        contentView.layoutIfNeeded()
        // Through the resolver, NOT `setActive(true)` — that convenience
        // applies the full wash unconditionally, which put a text page's
        // wash back every time the screen re-appeared.
        UIView.performWithoutAnimation { mediaBackdrop.setDim(backdropDim(at: 0)) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isActive = false
        // Instant (unanimated) disengage: a recycled cell must come back
        // full-bleed. Ordered before the media/chrome resets it restores.
        setCommentsEngaged(false)
        clearComments()
        onRequestComments = nil
        onRequestBoost = nil
        onRequestBoostUndo = nil
        onRequestCommentsClose = nil
        onRequestCommentsPageDrive = nil
        setPauseGlyphVisible(false)
        // ⚠️ A held chrome must never ride a recycled cell. A flight that is
        // cancelled, or a dismissal that ends the page instead of landing it,
        // leaves the hold un-released — and the next post to use this cell would
        // arrive with no chrome at all and nothing on the way to bring it back.
        chrome.alpha = 1
        cancelPrewarming()
        videoPlayback?.stop(mediaCard.renderView)
        // Reuse is the other door out, and a retained clip must not walk
        // through it into the next post.
        for view in mediaCard.releaseRetainedSurfaces() {
            videoPlayback?.stop(view)
        }
        representedID = nil
        mediaURL = nil
        mediaKind = .image
        // Back to the media ground AND the media theme: a recycled cell is a
        // media page until its next `configure` says otherwise, and a text
        // page's adaptive ground flashing behind an incoming photo is
        // exactly the kind of stranded state reuse produces.
        contentView.backgroundColor = .black
        contentView.overrideUserInterfaceStyle = SnapChromeTheme.style(hasMedia: true)
        for task in imageTasks { task.cancel() }
        imageTasks.removeAll()
        chrome.reset()
        mediaCard.setImage(nil)
        mediaCard.setPoster(nil)
    }
}

/// Marker class for the engaged comments region — the pager's per-touch
/// arbitration (`SnapFeedCell` hosts it, the feed VC's `claimsTouches`
/// consults it) declines drags born inside it, exactly the shortcut
/// rail's mechanism: inside the container the inner comments list
/// scrolls; outside it (the strip, the margins) the feed's paging takes
/// the touch.
final class SnapCommentsContainerView: UIView {}

extension SnapFeedCell {
    /// Keyboard-up hit arbitration: the risen composer's trailing ✕ lands
    /// inside the action rail's column, and the rail — interactive chrome
    /// layered ABOVE the comments container — would win those taps by
    /// z-order alone. While engaged, wherever the RAIL would take a touch,
    /// the container gets right of first refusal: if its own hit-test
    /// resolves to the composer at that point, the composer wins. The rail
    /// keeps every touch the composer doesn't physically overlap.
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        #if DEBUG
        if isCommentsEngaged, ProcessInfo.processInfo.arguments.contains("-gesture-log") {
            let chain = hit.map {
                sequence(first: $0, next: { $0.superview })
                    .prefix(8).map { "\(type(of: $0))(\(Int($0.frame.minY)))" }
                    .joined(separator: "<-")
            } ?? "nil"
            let bar = commentsContainer.subviews.first.map { child in
                child.subviews.compactMap { $0 as? CommentsInputBar }.first
                    .map { "barFrame=\($0.frame)" } ?? "no-bar-in-child"
            } ?? "no-child"
            print("GESTURELOG: cell hit at \(point) chain=\(chain) \(bar)")
        }
        #endif
        guard isCommentsEngaged, let hit else { return hit }
        // NOTE: the docked-media hit clip that used to live here is gone
        // with the dock. It existed because the crop mask trimmed PIXELS
        // and not hit-testing: the docked surface kept its full-bleed frame
        // under the uniform scale, so a z-lifted video tile ate stream
        // touches ~65pt above and below the visible square (an avatar tap
        // on the first comment row dismissed the whole engagement). The
        // media is neither transformed nor z-lifted now — it sits at the
        // back of the stack, beneath the stream — so the stream simply wins
        // its own touches by z-order and there is nothing to clip.
        // NOTE: the composer-vs-rail arbitration that used to live here is
        // gone too. The engaged composer rose into the shortcut rail's
        // column, and since the rail survived the engagement, every touch
        // in the overlap had to be re-routed to the bar by hand. The
        // engagement fades the rail out now — and UIKit does not hit-test a
        // view under alpha 0.01 — so there is no overlap left to referee.
        return hit
    }
}

// MARK: - Tap arbitration

extension SnapFeedCell: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The card's exit pan takes every touch it's offered — its own
        // begin-time gate (region + vertical intent + engagement) is the
        // filter, and it must see touches born on the card's metric
        // buttons too ("drag anywhere on the card").
        if gestureRecognizer === cardSwipeRecognizer { return true }
        // While engaged, the COMMENTS ZONE is tap-inert for the background
        // gesture: a touch landing anywhere in the hosted stream (rows,
        // gaps, the composer's band) must never collapse the engagement —
        // the explicit exits are the ✕, the strip zone, and the swipe
        // gestures. (The stream's own interactions — scrolling, row
        // controls, the composer — are untouched: declining the CELL's
        // tap takes nothing from views that own their touches.)
        if isCommentsEngaged,
           Self.isCommentsStreamTouch(touch.view, stopAt: contentView) {
            return false
        }
        return !Self.isInteractiveTouch(touch.view, interactiveRoots: chrome.interactionRoots, stopAt: contentView)
    }

    /// True when the touched view lives inside the engaged comments
    /// container — the zone where a tap means "interact with the stream",
    /// never "close the layout". Pure + static so the boundary is
    /// unit-testable, like `isInteractiveTouch`.
    static func isCommentsStreamTouch(_ touched: UIView?, stopAt: UIView) -> Bool {
        var view = touched
        while let current = view {
            if current is SnapCommentsContainerView { return true }
            if current === stopAt { break }
            view = current.superview
        }
        return false
    }

    /// True when the touched view is (or descends from) an interactive control —
    /// a `UIControl`, or any of `interactiveRoots` — walking up to `stopAt`. So
    /// taps on interactive chrome use those controls; taps on the background/
    /// media/caption toggle playback. Pure + static so the arbitration is
    /// unit-testable.
    static func isInteractiveTouch(_ touched: UIView?, interactiveRoots: [UIView], stopAt: UIView) -> Bool {
        var view = touched
        while let current = view {
            if current is UIControl { return true }
            if interactiveRoots.contains(where: { $0 === current }) { return true }
            if current === stopAt { break }
            view = current.superview
        }
        return false
    }
}


/// Runs a closure when a `CAAnimation` stops — completed OR removed.
///
/// Core Animation retains an animation's delegate for its lifetime, so this
/// needs no owner. It fires on removal too (`finished == false`), which is
/// what an interruptible transition wants: the caller decides whether the
/// world still needs the teardown, rather than the teardown being skipped
/// because the animation did not run to the end.
final class CALayerAnimationCompletion: NSObject, CAAnimationDelegate {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) {
        self.body = body
        super.init()
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        body()
    }
}
