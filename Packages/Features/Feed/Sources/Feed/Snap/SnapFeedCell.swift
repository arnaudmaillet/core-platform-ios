import MediaCore
import CoreModels
import DesignSystem
import MediaPlayback
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

    /// The media component: the video/photo render surfaces, their crop
    /// masks, and the top-left docking transform — one standalone card. The
    /// cell drives playback into `mediaCard.renderView` and gates the drift;
    /// the card owns the surfaces' geometry. Text posts leave it empty
    /// (surfaces hidden) — nothing docks.
    private let mediaCard = SnapMediaCardView()
    private let chrome = SnapChromeView()

    /// A large centred play glyph shown while the active video is user-paused.
    private let pauseGlyph = UIImageView()

    private var representedID: PostID?
    private var mediaURL: URL?
    /// Whether THIS post's caption fits on a single line (so the strip runs
    /// the COMPACT height — a shorter info card, a matching smaller media
    /// square, and the comments snug beneath). Resolved at `installComments`
    /// from the caption's single-line width vs the region, then the sole
    /// input to every strip-geometry call for the engagement's lifetime.
    private var isCompactCaption = false
    private var mediaKind: MediaKind = .image
    private var videoPlayback: VideoPlaybackController?
    private var imageTasks: [Task<Void, Never>] = []
    private var isActive = false

    // MARK: Comments engagement

    /// The user asked for the comments surface (the empty-state pill today;
    /// more entry points later). Carries the represented post.
    var onRequestComments: ((PostID) -> Void)?
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
    /// The header zone's wall-to-wall frost: screen top → the strip's
    /// lower boundary, layered BETWEEN the stream (behind) and the glass
    /// card (in front) — rows scrolled under the header dissolve into the
    /// blur while the open viewport below stays crisp; the floating card
    /// keeps its own stronger glass on top. HIT-INERT by construction
    /// (`isUserInteractionEnabled = false`): the engaged touch surface —
    /// card taps close, header-zone drags scroll the stream — must be
    /// exactly what it was before this layer existed. Effect nil until
    /// engagement IN A WINDOW (the headless-CI doctrine), animated via
    /// the `effect` property inside the master spring, like the card's.
    /// PROGRESSIVE: the band's gradient mask holds full frost through the
    /// nav zone and dissolves to zero at the partition line (locations
    /// re-tuned from the frozen insets at install) — rows scrolling up
    /// blend from crisp into blur with no geometric seam.
    private let headerFrost = ProgressiveFrostView(
        maskColors: [.black, .black, .clear],
        maskLocations: [0, 0.4, 1]
    )
    private var headerFrostConstraints: [NSLayoutConstraint] = []
    /// The post-info component: caption + right-aligned counters, its OWN
    /// floating glass card. Populated at `configure` (engaging is
    /// choreography, never a fetch); its content rests offstage (alpha 0,
    /// slight downward offset) and rises with the one engagement spring,
    /// carrying its caption. Positioned BESIDE the media card on media posts
    /// (`infoCardFrame(hasMedia: true)`), or standalone full-width on text
    /// posts — a distinct glass surface either way.
    private let infoCard = SnapPostInfoCardView()
    private var infoCardConstraints: [NSLayoutConstraint] = []
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        // Text-only posts' gradient page background lives inside the chrome
        // (shared with the hero flight's replica, so the landing swap can't
        // mismatch), not here. The media card hosts both render surfaces
        // full-bleed; it docks them into the strip slot when engaged.
        mediaCard.pin(to: contentView)

        // The comments region sits between the media (which vacates it when
        // docked) and the chrome (whose rail floats over it). Constraints
        // are minted at install (they depend on the frozen insets).
        // The comments stream: FULL cell height, layered BEHIND the docked
        // strip — its content rests below the strip via scroll inset and
        // glides underneath it when scrolled. No internal header: the
        // mutation itself says "comments".
        commentsContainer.backgroundColor = .black
        commentsContainer.isHidden = true
        commentsContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(commentsContainer)

        // The header frost sits directly above the stream and below the
        // two glass cards (added next), completing the z-sandwich: stream →
        // frost → cards → docked media.
        headerFrost.isHidden = true
        headerFrost.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerFrost)

        // The post-info glass card — its OWN floating surface (the media
        // card is a SEPARATE component with its own glass). Hidden and
        // unpositioned at rest; the feed positions it at `infoCardFrame`
        // per post (beside the media card, or standalone full-width) at
        // install. Its content rests offstage so engage/disengage are
        // symmetric legs of one spring with no per-engagement preparation.
        infoCard.isHidden = true
        infoCard.setContentEntrance(offstage: true)
        infoCard.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(infoCard)

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
        // The header zone's frost: wall-to-wall, screen top → the strip's
        // lower boundary (the comments partition line), dissolving from
        // solid behind the nav zone to nothing at the partition — the
        // ramp's start is the real inset boundary, not a guess.
        // COMPACT DECISION (once per engagement): the caption is single-
        // line when its natural width fits the info region — measured at
        // the COMPACT region (a text post's full strip, or the media post's
        // wider slot beside the SMALLER compact media square), so the choice
        // is self-consistent (a caption that fits the compact region stays
        // one line at the compact width). Every strip dimension below reads
        // this one flag.
        let stripWidth = SnapCommentsLayout.stripCardFrame(in: contentView.bounds, topInset: frozenInsets.top).width
        let compactRegion = mediaURL != nil
            ? stripWidth - SnapCommentsLayout.cardHeight(compact: true) - SnapCommentsLayout.cardGap
            : stripWidth
        isCompactCaption = infoCard.captionPreferredWidth <= compactRegion
        infoCard.setCompact(isCompactCaption)
        let compact = isCompactCaption

        headerFrost.setFadeLocations([
            0,
            NSNumber(value: Double(SnapCommentsLayout.headerFrostSolidFraction(topInset: frozenInsets.top))),
            1,
        ])
        headerFrost.isHidden = false
        NSLayoutConstraint.deactivate(headerFrostConstraints)
        headerFrostConstraints = [
            headerFrost.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerFrost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerFrost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerFrost.heightAnchor.constraint(
                equalToConstant: SnapCommentsLayout.stripBottom(topInset: frozenInsets.top, compact: compact)
            ),
        ]
        NSLayoutConstraint.activate(headerFrostConstraints)
        // The post-info glass card, positioned per post. Its WIDTH is
        // DYNAMIC — it hugs its content (short caption → narrow card),
        // floored at the card's own `minimumWidth` (the bottom row never
        // clips) and clamped to the available region below. Positioning
        // differs by format:
        //   • MEDIA — leading-pinned immediately right of the media card
        //     (`infoFrame.minX` = media card trailing + the card gap).
        //   • TEXT — CENTERED horizontally in the strip when narrower than
        //     the full width (no stretching into empty space).
        // The card hugs its intrinsic width (required hugging) up to the
        // region cap, so the caption wraps only when it would overflow.
        let infoFrame = SnapCommentsLayout.infoCardFrame(
            in: contentView.bounds, topInset: frozenInsets.top, hasMedia: mediaURL != nil, compact: compact
        )
        infoCard.isHidden = false
        infoCard.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.deactivate(infoCardConstraints)
        infoCardConstraints = [
            infoCard.topAnchor.constraint(equalTo: contentView.topAnchor, constant: infoFrame.minY),
            infoCard.heightAnchor.constraint(equalToConstant: infoFrame.height),
            // Never exceed the region (media-adjacent slot, or the full
            // strip for text); the intrinsic width fills below this.
            infoCard.widthAnchor.constraint(lessThanOrEqualToConstant: infoFrame.width),
        ]
        if mediaURL == nil {
            // Text: center within the strip; clamp inside its margins so a
            // full-width card still respects the strip edges.
            infoCardConstraints += [
                infoCard.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: infoFrame.midX),
                infoCard.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: infoFrame.minX),
            ]
        } else {
            // Media: leading-pinned right of the media card.
            infoCardConstraints.append(
                infoCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: infoFrame.minX)
            )
        }
        NSLayoutConstraint.activate(infoCardConstraints)
        // The docked media card rides ABOVE the stream and the frosted
        // header for the engagement's lifetime (restored on
        // `clearComments`) — that's the layering that makes comments glide
        // underneath it. It carries its OWN glass. (Hidden surfaces on a
        // text page make this a no-op visually — text posts show only the
        // info card.)
        contentView.insertSubview(mediaCard, aboveSubview: headerFrost)
        view.translatesAutoresizingMaskIntoConstraints = false
        commentsContainer.addSubview(view)
        view.pin(to: commentsContainer)
        contentView.layoutIfNeeded()
    }

    /// The trailing width the engaged comment rows must leave clear so the
    /// action rail's column is exclusively its own (zero overlap). Read
    /// after layout: the rail's leading edge is the boundary.
    var commentsRailExclusionWidth: CGFloat {
        chrome.railExclusionWidth
    }

    /// The engaged stream's top inset — the frosted strip's bottom edge. A
    /// single-line caption shrinks the cards, so this reads the cell's
    /// settled compact state (valid after `installComments`); the VC threads
    /// it into the hosted stream's `setEngagedInsets` so the rows start
    /// flush against the shorter frost.
    func engagedCommentsTopInset(safeAreaTop: CGFloat) -> CGFloat {
        SnapCommentsLayout.stripBottom(topInset: safeAreaTop, compact: isCompactCaption)
    }

    /// Reclaims the region after disengagement settles (the VC removes the
    /// child's view; this clears the cell-side scaffolding).
    func clearComments() {
        commentsContainer.subviews.forEach { $0.removeFromSuperview() }
        commentsContainer.isHidden = true
        commentsContainer.transform = .identity
        NSLayoutConstraint.deactivate(commentsContainerConstraints)
        commentsContainerConstraints = []
        infoCard.isHidden = true
        infoCard.setGlassActive(false)
        // A nudge interrupted by disengagement must not leak into the
        // next engagement's card position.
        infoCard.transform = .identity
        NSLayoutConstraint.deactivate(infoCardConstraints)
        infoCardConstraints = []
        mediaCard.hideGlass()
        headerFrost.isHidden = true
        headerFrost.effect = nil
        NSLayoutConstraint.deactivate(headerFrostConstraints)
        headerFrostConstraints = []
        // Restore the resting z-order: media at the bottom of the stack.
        contentView.sendSubviewToBack(mediaCard)
        mediaCard.clearMasks()
    }

    /// Applies or reverses the comments-engaged layout. Call inside a
    /// single `UIView.animate` spring block — every mutation here is
    /// animatable (media transform + corner radius, chrome surface alphas,
    /// caption flight, comments region lift), which is what keeps the
    /// whole state change ONE motion on ONE surface. The player is
    /// untouched by construction: its view's geometry animates, its
    /// ownership and clock never change.
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
        let bounds = contentView.bounds
        let slot = SnapCommentsLayout.mediaSlotFrame(in: bounds, topInset: frozenInsets.top, compact: isCompactCaption)

        if engaged {
            // The Ken Burns drift owns the same transform; it yields for the
            // engagement and resumes on disengage (below).
            stopKenBurns()
            if !pauseGlyph.isHidden {
                pauseGlyphSuppressedByEngagement = true
                pauseGlyph.isHidden = true
            }
            // The media card docks its surfaces into the slot (transform +
            // animated crop mask) and raises its OWN glass card around the
            // tile — a visual no-op for text posts, whose surfaces are
            // hidden and whose media card is never positioned. Inside the
            // master spring block.
            mediaCard.dock(slot: slot, in: bounds)
            if mediaURL != nil {
                mediaCard.showGlass(at: SnapCommentsLayout.mediaCardFrame(in: bounds, topInset: frozenInsets.top, compact: isCompactCaption))
            }
            chrome.setCommentsEngaged(true)
            commentsContainer.alpha = 1
            // Each card materializes its OWN glass via the EFFECT property
            // (the supported animatable path — alpha on an effect view is
            // not); window-guarded inside the component (real blurs contact
            // the render server, which headless CI hosts must never pay).
            infoCard.setGlassActive(true)
            // The header frost materializes on the same beat and the same
            // supported path — one material family across cards and frame.
            if window != nil, headerFrost.effect == nil {
                headerFrost.effect = UIBlurEffect(style: .systemThinMaterialDark)
            }
            // The info card's content rises into place inside the same
            // spring — one fade for the caption AND the counters (it owns
            // their internal balance); the chrome's caption copy fades out
            // on the same beat (`chrome.setCommentsEngaged`), the cross-fade.
            infoCard.setContentEntrance(offstage: false)
        } else {
            mediaCard.undock(in: bounds)
            mediaCard.hideGlass()
            chrome.setCommentsEngaged(false)
            commentsContainer.alpha = 0
            infoCard.setGlassActive(false) // blur dissolves with the return spring
            headerFrost.effect = nil
            // The info card's content sinks back to the entrance pose — the
            // reverse leg of the same spring, and the ready state for the
            // next engagement; the chrome caption fades back in as it fades
            // out.
            infoCard.setContentEntrance(offstage: true)
            if pauseGlyphSuppressedByEngagement {
                pauseGlyphSuppressedByEngagement = false
                pauseGlyph.isHidden = false
            }
            // Image pages resume their drift where activation would have
            // started it.
            if isActive { startKenBurns() }
        }
    }

    // MARK: - Configuration

    func configure(
        with model: FeedItemDisplayModel,
        pipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?
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
        let hasMedia = model.mediaURL != nil
        infoCard.setCaption(model.caption)
        infoCard.configure(with: model)
        // Composition is POSITIONAL now (the info card's frame is set at
        // install per `hasMedia`), so the info card itself is format-
        // agnostic — its caption always starts at its own inner padding.

        // The media card selects its surface for the kind and clears any
        // prior frame; a text post's surface simply never receives content.
        mediaCard.configure(kind: hasMedia ? model.mediaKind : .image)

        let isVideo = hasMedia && model.mediaKind == .video
        let isImage = hasMedia && model.mediaKind == .image
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
        chrome.updateCommentStreams(streams)
        // The info card's comment metric rides the same seam (and the
        // same known-zero honesty flag) as the chrome's surfaces.
        infoCard.setCommentCount(streams.commentCount, isLoaded: streams.isLoaded)
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
        imageTasks.append(Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            self.mediaCard.setImage(image)
            // If the media arrives after activation, kick the motion now.
            if self.isActive { self.startKenBurns() }
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
        switch mediaKind {
        case .video:
            guard let url = mediaURL, let videoPlayback else { return }
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
            let view = mediaCard.renderView
            Task { await videoPlayback.play(url, in: view) }
        case .image:
            startKenBurns()
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
            // The tile capped this item to a thumbnail rung; full screen wants
            // the whole ladder. Re-capped by URL because a joined surface holds
            // no pool loan and cannot be looked up by view.
            videoPlayback.setPeakBitRate(0, for: url)
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
        guard hasDeferredPlayback, isActive, mediaKind == .video,
              let url = mediaURL, let videoPlayback
        else { return }
        hasDeferredPlayback = false
        let view = mediaCard.renderView
        Task { await videoPlayback.play(url, in: view) }
    }

    /// Detaches this page's player and parks it for the next play of the same
    /// asset — the grid tile a dismissal is flying home to.
    @discardableResult
    func parkPlayback() -> Bool {
        guard mediaKind == .video, let videoPlayback else { return false }
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
        guard mediaKind == .video, let videoPlayback else { return nil }
        if VideoRenderFlags.usesSampleBufferLayer, let url = mediaURL {
            // Nothing is donated: the card gets a surface of its own on the
            // same playback, primed with the current frame, and this page keeps
            // rendering behind it. A cancelled grab therefore has nothing to
            // put back — see `reclaimDonatedPlayback`.
            let card = VideoRenderView()
            #if DEBUG
            card.debugLabel = "card"
            card.debugTracksFlight = true
            #endif
            guard videoPlayback.attachSurface(card, to: url) else { return nil }
            return card
        }
        guard videoPlayback.parkPlayback(from: mediaCard.renderView, keepingSurfaceAttached: true)
        else { return nil }
        let view = mediaCard.renderView
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
        guard let url = mediaURL, let videoPlayback else { return }
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

    /// The swipe's territory: the ENTIRE floating glass card — media,
    /// caption, music line, metrics — with a thumb-sized margin. The
    /// stream below the partition and the nav zone above the card stay
    /// out. Internal (not private) so the boundary is unit-testable.
    func cardSwipeRegionContains(_ point: CGPoint) -> Bool {
        SnapCommentsLayout.stripCardFrame(in: contentView.bounds, topInset: frozenInsets.top, compact: isCompactCaption)
            .insetBy(dx: -Spacing.sm, dy: -Spacing.sm)
            .contains(point)
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

    /// Toggles the active video's playback and reflects it in the pause glyph.
    /// No-op for image/text cells (no player).
    func togglePlayback() {
        guard mediaKind == .video, let videoPlayback else { return }
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
        guard mediaKind == .video, let videoPlayback else { return false }
        return videoPlayback.mirror(from: mediaCard.renderView, to: surface)
    }

    /// Re-asserts this cell as its player's display surface after a mirror
    /// surface goes away (a cancelled flight) — with multiple layers on one
    /// player, only the most recently attached is guaranteed to display.
    func reclaimPlayback() {
        guard mediaKind == .video, let videoPlayback else { return }
        videoPlayback.reclaim(mediaCard.renderView)
    }

    func didResignActive() {
        guard isActive else { return }
        isActive = false
        // Covers the paths visibility can't see: backgrounding and the
        // feed's own disappearance, where no `didEndDisplaying` fires.
        chrome.setTickerActive(false)
        chrome.setSubtitlesActive(false)
        switch mediaKind {
        case .video:
            videoPlayback?.stop(mediaCard.renderView)
        case .image:
            stopKenBurns()
        }
    }

    /// Phase 1's visible proof that activation works: a slow zoom on the active
    /// page's media. Phase 2 replaces this body with `player.play()`.
    private func startKenBurns() {
        // The engagement owns the media transform while docked — the cell
        // gates WHEN, the card owns the drift.
        guard !isCommentsEngaged else { return }
        mediaCard.startDrift()
    }

    private func stopKenBurns() {
        // The engagement OWNS the media transform while docked: stopping
        // the drift settles onto the CURRENT state's resting transform,
        // never a blind identity. The blind reset stranded the docked
        // tile as a frozen full-bleed center crop after an outbound push
        // (didResignActive fires with the engagement alive), and the
        // return could not heal it — startKenBurns rightly declines to
        // restart while engaged.
        let resting: CGAffineTransform
        if isCommentsEngaged {
            let bounds = contentView.bounds
            resting = SnapCommentsLayout.mediaTransform(
                bounds: bounds,
                slot: SnapCommentsLayout.mediaSlotFrame(in: bounds, topInset: frozenInsets.top, compact: isCompactCaption)
            )
        } else {
            resting = .identity
        }
        mediaCard.stopDrift(restingTransform: resting)
    }

    /// Keyboard-session rail yield (engaged only — the rail must never
    /// vanish from a resting page): see `SnapChromeView.setRailConcealed`.
    func setRailConcealed(_ concealed: Bool) {
        guard !concealed || isCommentsEngaged else { return }
        chrome.setRailConcealed(concealed)
    }

    /// Re-asserts the engaged dock geometry after the screen re-appears
    /// from an outbound push — the belt to `stopKenBurns`' brace, covering
    /// any path that disturbed the docked media while the feed was
    /// covered. The synchronous layout pass runs FIRST: the slot math
    /// must read settled coordinates, not a mid-transition hierarchy.
    /// Idempotent — re-applying the dock to an already-docked tile is a
    /// no-op.
    func reassertEngagedGeometry() {
        guard isCommentsEngaged else { return }
        contentView.layoutIfNeeded()
        let bounds = contentView.bounds
        let slot = SnapCommentsLayout.mediaSlotFrame(in: bounds, topInset: frozenInsets.top, compact: isCompactCaption)
        mediaCard.reassertDock(slot: slot, in: bounds)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isActive = false
        // Instant (unanimated) disengage: a recycled cell must come back
        // full-bleed. Ordered before the media/chrome resets it restores.
        setCommentsEngaged(false)
        clearComments()
        onRequestComments = nil
        onRequestCommentsClose = nil
        onRequestCommentsPageDrive = nil
        infoCard.reset()
        stopKenBurns()
        setPauseGlyphVisible(false)
        videoPlayback?.stop(mediaCard.renderView)
        representedID = nil
        mediaURL = nil
        mediaKind = .image
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
        // DOCKED-MEDIA HIT CLIP: the crop mask trims PIXELS, not
        // hit-testing — the docked render surface's frame is the full-
        // bleed rect under the uniform scale (88×191 on portrait cells),
        // extending ~65pt above and below the visible square tile. The
        // z-lifted surface would eat stream touches in that invisible
        // band (an avatar tap on the first comment row dismissed the
        // whole engagement — the background tap read it as a strip tap).
        // Touches on the media OUTSIDE the slot belong to whatever is
        // beneath; only image-inert cells escaped by accident
        // (UIImageView doesn't hit-test; the video surface does).
        if mediaCard.containsSurface(hit) {
            let slot = SnapCommentsLayout.mediaSlotFrame(
                in: contentView.bounds, topInset: frozenInsets.top, compact: isCompactCaption
            )
            if !slot.contains(convert(point, to: contentView)) {
                let containerPoint = convert(point, to: commentsContainer)
                if let beneath = commentsContainer.hitTest(containerPoint, with: event) {
                    return beneath
                }
            }
            return hit
        }
        guard sequence(first: hit, next: { $0.superview }).contains(where: { $0 is SnapShortcutRailView })
        else { return hit }
        let containerPoint = convert(point, to: commentsContainer)
        if let inner = commentsContainer.hitTest(containerPoint, with: event),
           sequence(first: inner, next: { $0.superview }).contains(where: { $0 is CommentsInputBar }) {
            return inner
        }
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
