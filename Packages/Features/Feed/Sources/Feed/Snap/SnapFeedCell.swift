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
    private var mediaURL: URL?
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
            // The drift yields for the engagement: a slowly zooming photo
            // under body text is a readability problem, and the background
            // should read as STILL while the reader is in the comments. It
            // resumes on disengage (below).
            stopKenBurns()
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
        // THE PAGE'S GROUND. A media page is black because black is what
        // letterboxing should be — the surface exists to disappear behind a
        // photo. A TEXT page has nothing to disappear behind, so its ground
        // is the page itself and it follows the system appearance.
        contentView.backgroundColor = hasMedia ? .black : .systemBackground
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
            if isActive { startKenBurns() }
            return
        }
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
        guard isActive, mediaKind == .video,
              let url = mediaURL, let videoPlayback
        else { return }
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
        Task { await videoPlayback.play(url, in: view) }
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
        // The background must read STILL while the reader is in the
        // comments — the cell gates WHEN, the card owns the drift.
        guard !isCommentsEngaged else { return }
        mediaCard.startDrift()
    }

    private func stopKenBurns() {
        // Unconditional identity. This used to have to compute a resting
        // transform per state, because the engagement and the drift shared
        // the surfaces' transform while the media docked; the engagement's
        // recede now lives on the card itself, so the drift owns the
        // surface transform outright and there is no state to consult.
        mediaCard.stopDrift()
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
        onRequestCommentsClose = nil
        onRequestCommentsPageDrive = nil
        stopKenBurns()
        setPauseGlyphVisible(false)
        videoPlayback?.stop(mediaCard.renderView)
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
