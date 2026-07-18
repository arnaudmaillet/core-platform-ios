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

    private let mediaView = UIImageView()
    private let videoRenderView = VideoRenderView()
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
    /// Whether the cell is in the comments-engaged layout (media docked in
    /// the strip's slot, chrome faded out, caption re-homed beside the
    /// media). Pure layout state: playback is deliberately untouched.
    private(set) var isCommentsEngaged = false
    /// The caption's engaged-state home, beside the docked media. A separate
    /// label (not the chrome's) so the chrome's overlay stack keeps its
    /// full-bleed geometry doctrine untouched; content is copied at
    /// `configure`.
    private let engagedCaptionLabel = UILabel()
    private var engagedCaptionConstraints: [NSLayoutConstraint] = []
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
    /// The frosted header behind the docked strip: comments glide under it
    /// at full height, the blur keeps the strip legible. Effect nil until
    /// engagement IN A WINDOW (creating a real `UIBlurEffect` contacts the
    /// render server — the headless-CI stall doctrine), and the blur
    /// animates in/out via the `effect` property, the supported path.
    private let stripBackdrop = UIVisualEffectView(effect: nil)
    private var stripBackdropConstraints: [NSLayoutConstraint] = []
    /// The card's content: the post's full identity suite (author header,
    /// music line, metrics/actions), living inside the backdrop's content
    /// view so the glass frame is its only geometry authority. Populated at
    /// `configure` (engaging is choreography, never a fetch); rests
    /// offstage (alpha 0, slight downward offset) and rises with the one
    /// engagement spring. The media and the caption stay cell-level
    /// siblings above it — the media docks by transform, the caption flies.
    private let engagedCard = SnapEngagedPostCardView()
    /// Whether the represented post renders the card's music line — the
    /// caption column must stop above it (`captionColumnMaxY`).
    private var engagedHasAudioLine = false
    /// Center-crop masks that square the docked media (one per render
    /// surface — a view can mask only one other view). Attached lazily at
    /// engage, animated full-bounds ↔ centered-square within the same
    /// spring as the transform, removed once the region is reclaimed.
    private let mediaCropMask = UIView()
    private let videoCropMask = UIView()
    /// Remembers a visible pause glyph across an engagement (the glyph is
    /// centered on the full page and would float mid-strip while docked).
    private var pauseGlyphSuppressedByEngagement = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true

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

        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        // Text-only posts' gradient page background lives inside the chrome
        // (shared with the hero flight's replica, so the landing swap can't
        // mismatch), not here.
        mediaView.pin(to: contentView)
        videoRenderView.pin(to: contentView)

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

        // The strip's Liquid Glass CARD, above the stream and below the
        // media: a floating rounded surface (not a wall-to-wall band) with
        // a hairline stroke, so the under-gliding comments read as passing
        // BEHIND a distinct object. Blur clipping needs `clipsToBounds`
        // (an effect view's backdrop ignores the layer radius on its own —
        // the count bubble's doctrine).
        stripBackdrop.isHidden = true
        stripBackdrop.clipsToBounds = true
        stripBackdrop.layer.cornerRadius = SnapCommentsLayout.stripCardCornerRadius
        stripBackdrop.layer.cornerCurve = .continuous
        stripBackdrop.layer.borderWidth = 0.5
        stripBackdrop.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        stripBackdrop.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stripBackdrop)

        // The card content rides the backdrop, resting offstage: the
        // disengage pose IS the entrance pose (alpha 0, a small downward
        // offset), so engage/disengage are symmetric legs of one spring
        // with no per-engagement preparation.
        engagedCard.alpha = 0
        engagedCard.transform = CGAffineTransform(
            translationX: 0, y: SnapCommentsLayout.cardContentEntranceOffset
        )
        engagedCard.translatesAutoresizingMaskIntoConstraints = false
        stripBackdrop.contentView.addSubview(engagedCard)
        engagedCard.pin(to: stripBackdrop.contentView)

        chrome.pin(to: contentView)

        // Centred pause glyph (added last so it sits above the media/chrome).
        pauseGlyph.constrain(in: contentView) { parent in
            pauseGlyph.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            pauseGlyph.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        // The engaged caption: hidden until the comments engagement re-homes
        // the description beside the docked media. Constraints are minted per
        // engagement (they depend on the slot rect).
        engagedCaptionLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        engagedCaptionLabel.adjustsFontForContentSizeCategory = true
        engagedCaptionLabel.textColor = .white
        // The FULL caption, sized to the column: the line cap is computed
        // per engagement from the column's height (`captionLineCapacity`),
        // so the caption uses everything between the media row's top and
        // the music line; the ellipsis stays the truth-teller only when
        // the column genuinely overflows.
        engagedCaptionLabel.numberOfLines = 0
        engagedCaptionLabel.lineBreakMode = .byTruncatingTail
        engagedCaptionLabel.alpha = 0
        engagedCaptionLabel.isHidden = true
        engagedCaptionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(engagedCaptionLabel)
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
        // The glass card floats around the strip's content.
        let card = SnapCommentsLayout.stripCardFrame(
            in: contentView.bounds, topInset: frozenInsets.top
        )
        stripBackdrop.isHidden = false
        NSLayoutConstraint.deactivate(stripBackdropConstraints)
        stripBackdropConstraints = [
            stripBackdrop.topAnchor.constraint(equalTo: contentView.topAnchor, constant: card.minY),
            stripBackdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: card.minX),
            stripBackdrop.widthAnchor.constraint(equalToConstant: card.width),
            stripBackdrop.heightAnchor.constraint(equalToConstant: card.height),
        ]
        NSLayoutConstraint.activate(stripBackdropConstraints)
        // The docked media rides ABOVE the stream and the frosted header
        // for the engagement's lifetime (restored on `clearComments`) —
        // that's the layering that makes comments glide underneath it.
        contentView.insertSubview(mediaView, aboveSubview: stripBackdrop)
        contentView.insertSubview(videoRenderView, aboveSubview: mediaView)
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

    /// Reclaims the region after disengagement settles (the VC removes the
    /// child's view; this clears the cell-side scaffolding).
    func clearComments() {
        commentsContainer.subviews.forEach { $0.removeFromSuperview() }
        commentsContainer.isHidden = true
        commentsContainer.transform = .identity
        NSLayoutConstraint.deactivate(commentsContainerConstraints)
        commentsContainerConstraints = []
        stripBackdrop.isHidden = true
        stripBackdrop.effect = nil
        NSLayoutConstraint.deactivate(stripBackdropConstraints)
        stripBackdropConstraints = []
        // Restore the resting z-order: media at the bottom of the stack.
        contentView.sendSubviewToBack(videoRenderView)
        contentView.sendSubviewToBack(mediaView)
        mediaView.mask = nil
        videoRenderView.mask = nil
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
        let bounds = contentView.bounds
        let slot = SnapCommentsLayout.mediaSlotFrame(in: bounds, topInset: frozenInsets.top)

        if engaged {
            // The Ken Burns drift owns the same transform; it yields for the
            // engagement and resumes on disengage (below).
            stopKenBurns()
            if !pauseGlyph.isHidden {
                pauseGlyphSuppressedByEngagement = true
                pauseGlyph.isHidden = true
            }
            let transform = SnapCommentsLayout.mediaTransform(bounds: bounds, slot: slot)
            let crop = SnapCommentsLayout.mediaCropFrame(in: bounds)
            let scale = slot.width / max(min(bounds.width, bounds.height), 1)
            for (view, mask) in [(mediaView, mediaCropMask), (videoRenderView, videoCropMask)] {
                // The mask squares the tile by re-CROPPING (never squashing):
                // attached at full bounds (invisible) outside the animation,
                // then its frame closes to the centered square inside the
                // spring, in step with the docking transform. The corner
                // radius lives on the mask (it owns the visible shape),
                // compensated for the scale it will be drawn under.
                if view.mask == nil {
                    UIView.performWithoutAnimation {
                        mask.backgroundColor = .black
                        mask.frame = bounds
                        mask.layer.cornerCurve = .continuous
                        view.mask = mask
                    }
                }
                mask.layer.cornerRadius = SnapCommentsLayout.mediaCornerRadius / scale
                mask.frame = crop
                view.transform = transform
            }
            chrome.setCommentsEngaged(true)
            commentsContainer.alpha = 1
            // The frosted header materializes via the EFFECT property (the
            // supported animatable path — alpha on an effect view is not).
            // Window-guarded: real blurs contact the render server, which
            // headless CI test hosts must never pay.
            if window != nil, stripBackdrop.effect == nil {
                stripBackdrop.effect = UIBlurEffect(style: .systemThinMaterialDark)
            }
            // The card's rows rise into place inside the same spring — the
            // composer-entrance recipe at card scale.
            engagedCard.alpha = 1
            engagedCard.transform = .identity
            engagedCaptionLabel.isHidden = false
            // The column's line budget: everything between the media row's
            // top and the music line, in whole lines (a height-compressed
            // label center-clips; only the line cap truncates honestly).
            let columnTop = slot.minY + Spacing.xs
            let columnMaxY = SnapCommentsLayout.captionColumnMaxY(
                slotMaxY: slot.maxY, hasAudioLine: engagedHasAudioLine
            )
            engagedCaptionLabel.numberOfLines = SnapCommentsLayout.captionLineCapacity(
                columnHeight: columnMaxY - columnTop,
                lineHeight: engagedCaptionLabel.font.lineHeight
            )
            NSLayoutConstraint.deactivate(engagedCaptionConstraints)
            engagedCaptionConstraints = [
                engagedCaptionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: slot.maxX + Spacing.md),
                engagedCaptionLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: columnTop),
                engagedCaptionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.lg),
                engagedCaptionLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.topAnchor, constant: columnMaxY),
            ]
            NSLayoutConstraint.activate(engagedCaptionConstraints)
            // The caption FLIES: the chrome's copy vanishes instantly (never
            // two captions on screen) and this label starts the animation
            // pre-transformed onto the old caption's frame at the old type
            // scale — settled without animation so the subsequent identity
            // assignment (inside the caller's animation block) is the flight
            // itself. When the post has no caption, it simply fades in with
            // the strip.
            let source = chrome.captionFlightSourceFrame
            chrome.setCaptionConcealed(true)
            UIView.performWithoutAnimation {
                engagedCaptionLabel.transform = .identity // clear any stale flight
                contentView.layoutIfNeeded()
                if let source {
                    engagedCaptionLabel.alpha = 1
                    engagedCaptionLabel.transform = SnapCommentsLayout.captionFlightTransform(
                        finalFrame: engagedCaptionLabel.frame,
                        sourceFrame: source,
                        scale: SnapCommentsLayout.captionFlightScale()
                    )
                } else {
                    engagedCaptionLabel.alpha = 0
                }
            }
            engagedCaptionLabel.transform = .identity
            engagedCaptionLabel.alpha = 1
        } else {
            for (view, mask) in [(mediaView, mediaCropMask), (videoRenderView, videoCropMask)] {
                view.transform = .identity
                // The crop reopens with the expansion; the mask itself is
                // removed once the layout settles (`clearComments`) — a
                // full-bounds mask is visually inert but not free.
                if view.mask != nil {
                    mask.frame = bounds
                    mask.layer.cornerRadius = 0
                }
            }
            chrome.setCommentsEngaged(false)
            commentsContainer.alpha = 0
            stripBackdrop.effect = nil // blur dissolves with the return spring
            // The card's rows sink back to the entrance pose — the reverse
            // leg of the same spring, and the ready state for the next
            // engagement.
            engagedCard.alpha = 0
            engagedCard.transform = CGAffineTransform(
                translationX: 0, y: SnapCommentsLayout.cardContentEntranceOffset
            )
            // Reverse flight: the chrome caption returns with the chrome's
            // fade-in while this label flies back onto its frame, fading —
            // a cross-dissolve in motion, no completion hooks to sequence.
            chrome.setCaptionConcealed(false)
            if let source = chrome.captionFlightSourceFrame {
                // The label's UNtransformed frame, from center/bounds — valid
                // even if a cancelled flight left a transform in place.
                let settled = CGRect(
                    x: engagedCaptionLabel.center.x - engagedCaptionLabel.bounds.width / 2,
                    y: engagedCaptionLabel.center.y - engagedCaptionLabel.bounds.height / 2,
                    width: engagedCaptionLabel.bounds.width,
                    height: engagedCaptionLabel.bounds.height
                )
                engagedCaptionLabel.transform = SnapCommentsLayout.captionFlightTransform(
                    finalFrame: settled,
                    sourceFrame: source,
                    scale: SnapCommentsLayout.captionFlightScale()
                )
            }
            engagedCaptionLabel.alpha = 0
            NSLayoutConstraint.deactivate(engagedCaptionConstraints)
            engagedCaptionConstraints = []
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
        chrome.onCommentsTapped = { [weak self] in
            guard let self, let id = self.representedID, !self.isCommentsEngaged else { return }
            self.onRequestComments?(id)
        }
        engagedCaptionLabel.text = model.caption
        engagedCard.configure(with: model, pipeline: pipeline)
        engagedHasAudioLine = model.audioText != nil

        let hasMedia = model.mediaURL != nil
        let isVideo = hasMedia && model.mediaKind == .video
        let isImage = hasMedia && model.mediaKind == .image
        mediaView.isHidden = !isImage
        videoRenderView.isHidden = !isVideo

        mediaView.image = nil
        mediaView.transform = .identity
        videoRenderView.setPoster(nil)

        if isImage {
            loadImage(model.mediaURL, into: mediaView, expecting: model.id, pipeline: pipeline)
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
            self.videoRenderView.setPoster(image)
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
        // The engaged card's comment metric rides the same seam (and the
        // same known-zero honesty flag) as the chrome's surfaces.
        engagedCard.setCommentCount(streams.commentCount, isLoaded: streams.isLoaded)
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

    private func loadImage(_ url: URL?, into imageView: UIImageView, expecting id: PostID, pipeline: ImagePipeline) {
        guard let url else { return }
        imageTasks.append(Task { [weak self, weak imageView] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            imageView?.image = image
            // If the media arrives after activation, kick the motion now.
            if imageView === self.mediaView, self.isActive {
                self.startKenBurns()
            }
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
            let view = videoRenderView
            Task { await videoPlayback.play(url, in: view) }
        case .image:
            startKenBurns()
        }
    }

    // MARK: - Play/pause toggle

    @objc private func handleBackgroundTap() {
        // While engaged, the strip is the only cell territory the panel
        // doesn't cover — a tap there means "expand back", not play/pause.
        if isCommentsEngaged {
            onRequestCommentsClose?()
            return
        }
        togglePlayback()
    }

    /// Toggles the active video's playback and reflects it in the pause glyph.
    /// No-op for image/text cells (no player).
    func togglePlayback() {
        guard mediaKind == .video, let videoPlayback else { return }
        let paused = videoPlayback.togglePlayback(in: videoRenderView)
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
        return videoPlayback.mirror(from: videoRenderView, to: surface)
    }

    /// Re-asserts this cell as its player's display surface after a mirror
    /// surface goes away (a cancelled flight) — with multiple layers on one
    /// player, only the most recently attached is guaranteed to display.
    func reclaimPlayback() {
        guard mediaKind == .video, let videoPlayback else { return }
        videoPlayback.reclaim(videoRenderView)
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
            videoPlayback?.stop(videoRenderView)
        case .image:
            stopKenBurns()
        }
    }

    /// Phase 1's visible proof that activation works: a slow zoom on the active
    /// page's media. Phase 2 replaces this body with `player.play()`.
    private func startKenBurns() {
        // The engagement owns the media transform while docked.
        guard mediaView.image != nil, !mediaView.isHidden, !isCommentsEngaged else { return }
        mediaView.layer.removeAllAnimations()
        UIView.animate(withDuration: 8, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
            self.mediaView.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        }
    }

    private func stopKenBurns() {
        mediaView.layer.removeAllAnimations()
        UIView.performWithoutAnimation { self.mediaView.transform = .identity }
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
        engagedCaptionLabel.text = nil
        engagedCaptionLabel.transform = .identity
        engagedCard.reset()
        engagedHasAudioLine = false
        stopKenBurns()
        setPauseGlyphVisible(false)
        videoPlayback?.stop(videoRenderView)
        representedID = nil
        mediaURL = nil
        mediaKind = .image
        for task in imageTasks { task.cancel() }
        imageTasks.removeAll()
        chrome.reset()
        mediaView.image = nil
        videoRenderView.setPoster(nil)
    }
}

/// Marker class for the engaged comments region — the pager's per-touch
/// arbitration (`SnapFeedCollectionView.gestureRecognizerShouldBegin`)
/// declines drags born inside it, exactly the shortcut rail's mechanism:
/// inside the container the inner comments list scrolls; outside it (the
/// strip, the margins) the feed's paging takes the touch.
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
        guard isCommentsEngaged, let hit,
              sequence(first: hit, next: { $0.superview }).contains(where: { $0 is SnapShortcutRailView })
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
        !Self.isInteractiveTouch(touch.view, interactiveRoots: chrome.interactionRoots, stopAt: contentView)
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
