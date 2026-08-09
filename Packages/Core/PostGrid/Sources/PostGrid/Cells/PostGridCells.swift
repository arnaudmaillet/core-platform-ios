import DesignSystem
import MediaCore
import MediaPlayback
import UIKit

// MARK: - Timeline row

/// One full-width row of the Activity/Short timelines: the caption with
/// reading padding on a soft card, plus — when the post carries media — a
/// rounded full-width preview under the text (play badge for videos), and a
/// quiet metadata line closing the card: views, reactions, comments on the
/// leading side, the post's compact age trailing. Short pages never have
/// media, so their rows are text + metadata.
public final class PostGridListRowCell: UICollectionViewCell {
    public static let reuseID = "PostGridListRowCell"
    /// The inner preview's rounding — the radius a hero flying from this row
    /// must start at, so the card is the preview's twin rather than its
    /// approximation.
    public static let mediaCornerRadius: CGFloat = 12

    /// The preview's rect in this cell's own space, or nil for a text-only row
    /// (which has no media to fly). A hero source reads this to decide whether
    /// a row can host a flight at all.
    public var mediaHeroRect: CGRect? {
        guard !mediaView.isHidden else { return nil }
        layoutIfNeeded()
        return mediaView.frame
    }

    /// The image the preview is currently showing — the exact pixels the
    /// viewer is looking at, so a flight starts from them rather than from a
    /// cache lookup that could miss.
    public var renderedCover: UIImage? { mediaView.image }

    /// The preview box — a row's media is one part of its card, so this is the
    /// part visibility is measured against. Falls back to the whole cell only
    /// for a text row, which has no video to measure anyway.
    public var videoMediaRect: CGRect { mediaHeroRect ?? bounds }

    // MARK: - Autoplay surface

    /// The surface an autoplaying row renders into, built on first use so a
    /// timeline of stills never allocates a player layer it will not use.
    ///
    /// Placed INSIDE the preview box, unlike the tile's, which fills the whole
    /// cell. That is the row's shape talking: the media is one part of a card,
    /// so the video has to be clipped to the part — and putting it in the box
    /// also means it inherits the box's rounding and, for free, the alpha that
    /// `setHeroMediaConcealed` applies while a twin is in the air. A sibling
    /// surface would have needed concealing separately, and would have been
    /// the thing left visible over a flight.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        if let loadedVideoRenderView { return loadedVideoRenderView }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "row"
        #endif
        view.isHidden = true
        view.isUserInteractionEnabled = false
        mediaView.addSubview(view)
        view.pin(to: mediaView)
        sendVideoSurfaceBelowBadge(view)
        loadedVideoRenderView = view
        return view
    }

    public private(set) var loadedVideoRenderView: VideoRenderView?

    public func adoptVideoRenderView(_ view: VideoRenderView) {
        if let existing = loadedVideoRenderView, existing !== view {
            existing.detachForReplacement()
            existing.removeFromSuperview()
        }
        view.transform = .identity
        view.isHidden = false
        mediaView.addSubview(view)
        view.pin(to: mediaView)
        sendVideoSurfaceBelowBadge(view)
        loadedVideoRenderView = view
    }

    /// Keeps the ▶ glyph over the video, the way the tile keeps its furniture
    /// over a playing brick: the badge is what tells a video row apart, and it
    /// should read the same whether the preview is a still or moving.
    ///
    /// Separate from the `pin` above, and it has to be — `pin(to:)` begins with
    /// `addSubview`, which moves the view to the FRONT. Ordering the surface
    /// before pinning it is therefore silently undone, which is exactly what
    /// happened: the first playing row rendered correctly with its badge gone.
    private func sendVideoSurfaceBelowBadge(_ view: VideoRenderView) {
        mediaView.insertSubview(view, belowSubview: playBadge)
    }

    public func donateVideoRenderView() -> VideoRenderView? {
        guard let view = loadedVideoRenderView else { return nil }
        loadedVideoRenderView = nil
        view.removeFromSuperview()
        return view
    }

    /// Reveals the surface once a player has been attached. The cover stays
    /// underneath as the poster, so the first frame replaces it rather than
    /// flashing black.
    public func beginVideoPreview() {
        let view = makeVideoRenderViewIfNeeded()
        view.setPoster(mediaView.image)
        view.revealOnFirstFrame()
    }

    /// Back to a still row. Faded rather than switched off, so a sweep that
    /// stops several rows at once does not snap their covers back in one frame.
    public func endVideoPreview() {
        loadedVideoRenderView?.hideCrossFading()
    }

    /// Puts a cover on immediately, without waiting for the async load already
    /// in flight — the same race the tile closes, for the same reason: the
    /// autoplay gate must not pass on a cover the row is not actually showing.
    public func applyCover(_ image: UIImage) {
        guard mediaView.image == nil else { return }
        mediaView.image = image
        loadedVideoRenderView?.setPoster(image)
    }

    /// Fired when the cover lands from an async load, so the autoplay gate is
    /// re-run for a row that arrived faceless.
    public var onCoverLoaded: (() -> Void)?

    /// Called when the collection view recycles this row, so the coordinator
    /// takes its player back before the cell is bound to another post.
    public var onReuse: (() -> Void)?

    /// Hides ONLY the preview while its twin is in the air.
    ///
    /// A row is a card of which the media is one part, and the flight carries
    /// that part (`mediaHeroRect`) — so that part is exactly what must
    /// disappear. Hiding the whole cell instead, which is what a tile needs,
    /// took the caption, the author line and the metrics with it: they were
    /// missing for the length of the flight and snapped back at its last
    /// frame, because nothing in the air was standing in for them.
    ///
    /// The invariant, in one line: CONCEAL EXACTLY WHAT THE FLIGHT
    /// REPRODUCES. A tile is its media, so the tile hides whole; a row is not,
    /// so it does not. A text row never flies at all — it pushes natively.
    ///
    /// Alpha, not `isHidden`, and that is load-bearing: `mediaHeroRect`
    /// reports nil for a hidden preview, so hiding it would make the row
    /// unable to answer where its own media is — which is the rect the
    /// DISMISSAL flies home to.
    public func setHeroMediaConcealed(_ concealed: Bool) {
        mediaView.alpha = concealed ? 0 : 1
        playBadge.alpha = concealed ? 0 : 1
    }


    /// The card's own rounding and fill, so a flight impersonating this row
    /// is its twin rather than an approximation of it. Restating either as a
    /// literal in the flight card is how the two drift.
    public static let cardCornerRadius: CGFloat = 18
    public static let cardFillColor: UIColor = .secondarySystemBackground
    /// The caption's type and inset, for the same reason.
    public static let captionInset: CGFloat = 16
    public static let captionTopInset: CGFloat = 16
    /// The closing metric line's placement, shared with the flight card that
    /// stands in for a text row.
    public static let metaBottomInset: CGFloat = 14
    public static let metaSpacing: CGFloat = 14

    private let card = UIView()
    private let captionLabel = UILabel()
    private let mediaView = UIImageView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.preferredFont(forTextStyle: .footnote)
    private let reactions = PostMetricLabel(symbol: "heart", font: metaFont, color: .secondaryLabel)
    private let comments = PostMetricLabel(symbol: "bubble.right", font: metaFont, color: .secondaryLabel)
    private let views = PostMetricLabel(symbol: "eye", font: metaFont, color: .secondaryLabel)
    private let ageLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    /// Swapped per configure: the metadata line hangs off the caption for
    /// text-only rows; media rows interpose the preview.
    private var metaFollowsCaption: NSLayoutConstraint!
    private var mediaConstraints: [NSLayoutConstraint] = []

    override public init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = Self.cardFillColor
        card.layer.cornerRadius = Self.cardCornerRadius
        card.layer.cornerCurve = .continuous
        card.pin(to: contentView)

        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 0
        captionLabel.constrain(in: card) { parent in
            captionLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: Self.captionTopInset)
            captionLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Self.captionInset)
            captionLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.captionInset)
        }

        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true
        mediaView.layer.cornerRadius = 12
        mediaView.layer.cornerCurve = .continuous
        card.addSubview(mediaView)
        mediaView.translatesAutoresizingMaskIntoConstraints = false

        playBadge.tintColor = .white
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        playBadge.constrain(in: mediaView) { parent in
            playBadge.topAnchor.constraint(equalTo: parent.topAnchor, constant: 10)
            playBadge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10)
        }

        ageLabel.font = Self.metaFont
        ageLabel.textColor = .secondaryLabel
        ageLabel.adjustsFontForContentSizeCategory = true
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        // Views lead, reactions and comments follow — the same reach-first
        // order as the media tiles' counter pair.
        let metaRow = UIStackView(arrangedSubviews: [views, reactions, comments, spacer, ageLabel])
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        metaRow.spacing = Self.metaSpacing
        metaRow.constrain(in: card) { parent in
            metaRow.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Self.captionInset)
            metaRow.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.captionInset)
            metaRow.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Self.metaBottomInset)
        }
        metaFollowsCaption = metaRow.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12)
        metaFollowsCaption.isActive = true
        mediaConstraints = [
            mediaView.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12),
            mediaView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            mediaView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            mediaView.heightAnchor.constraint(equalToConstant: 180),
            metaRow.topAnchor.constraint(equalTo: mediaView.bottomAnchor, constant: 12)
        ]
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // Hand the player back BEFORE anything else: a recycled row that kept
        // its loan would show the previous post's video under the new post's
        // cover. The coordinator clears its own bookkeeping in response.
        onReuse?()
        onReuse = nil
        onCoverLoaded = nil
        endVideoPreview()
        // Concealment is per-flight state and must not ride a recycled cell to
        // whatever post it is bound to next — the row equivalent of the tile's
        // `isHidden` reset.
        setHeroMediaConcealed(false)
        loadTask?.cancel()
        loadTask = nil
        mediaView.image = nil
    }

    public func configure(with post: GalleryPost, imagePipeline: ImagePipeline) {
        captionLabel.text = post.caption
        let hasMedia = post.kind != .text
        mediaView.isHidden = !hasMedia
        playBadge.isHidden = post.kind != .video
        metaFollowsCaption.isActive = !hasMedia
        NSLayoutConstraint.deactivate(hasMedia ? [] : mediaConstraints)
        NSLayoutConstraint.activate(hasMedia ? mediaConstraints : [])

        reactions.set(post.reactionCount)
        comments.set(post.commentCount)
        views.set(post.viewCount)
        ageLabel.text = PostMetadata.compactAge(ofMillis: post.publishedAtMS)

        mediaView.image = nil
        mediaView.backgroundColor = post.kind == .video ? .darkGray : .tertiarySystemFill
        guard hasMedia, let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            mediaView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled else { return }
            guard let self else { return }
            UIView.transition(
                with: self.mediaView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.mediaView.image = image
            }
            // The row now has a face, which is the one thing the autoplay gate
            // was waiting for. Nothing else would ask again while the timeline
            // sits still.
            loadedVideoRenderView?.setPoster(image)
            onCoverLoaded?()
        }
    }
}

extension PostGridListRowCell: GridPlaybackCell {}

// MARK: - Media tile

/// One square of the Media grid: photo thumbnail, or video poster + badge,
/// with the compact counter pair (reactions, views) resting bottom-leading —
/// caption2 over a soft shadow, no scrim, so the preview stays the star.
public final class PostGridTileCell: UICollectionViewCell {
    public static let reuseID = "PostGridTileCell"

    /// The mosaic's rounding, and the default: it is paired with that layout's
    /// 1.5pt hairline gutter, where anything softer would leave visible pinches
    /// where four bricks meet.
    public static let mosaicCornerRadius: CGFloat = 10

    /// The brick's rounding, settable because the two grids that share this
    /// cell space their tiles differently — see
    /// `ChaoticSliceLayout.harmonisedGutter`. Gap and curve are one decision,
    /// so a surface that widens the gap sets this to match.
    public var cornerRadius: CGFloat = PostGridTileCell.mosaicCornerRadius {
        didSet { contentView.layer.cornerRadius = cornerRadius }
    }

    /// The image the brick is currently showing — see `PostGridListRowCell`'s
    /// note for why a hero reads this rather than the image pipeline.
    public var renderedCover: UIImage? { imageView.image }

    /// A tile IS its media, edge to edge, so the whole cell is the rect
    /// visibility is measured against.
    public var videoMediaRect: CGRect { bounds }

    /// The surface an autoplaying tile renders into, built on first use so a
    /// grid of stills never allocates a player layer it will not use.
    ///
    /// Not a `lazy var`: the coordinator needs to ask whether a cell *could* be
    /// playing (`loadedVideoRenderView`) without the question itself allocating
    /// the layer, which is exactly what touching a lazy var would do.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        if let loadedVideoRenderView { return loadedVideoRenderView }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "tile"
        #endif
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Above the still, below the badge and counters, so the furniture keeps
        // reading over moving video exactly as it does over a poster.
        contentView.insertSubview(view, aboveSubview: imageView)
        loadedVideoRenderView = view
        return view
    }

    /// The video surface if one was ever built, else nil — never allocates.
    public private(set) var loadedVideoRenderView: VideoRenderView?

    /// Installs a flight card's live surface as this tile's own, at landing.
    ///
    /// The view arrives already rendering, so the tile has nothing to wait for
    /// — the alternative is starting a fresh layer that is blank for ~100ms
    /// just as the card is removed, which is the flash at the end of a
    /// dismissal.
    public func adoptVideoRenderView(_ view: VideoRenderView) {
        if let existing = loadedVideoRenderView, existing !== view {
            existing.detachForReplacement()
            existing.removeFromSuperview()
        }
        view.transform = .identity
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isHidden = false
        contentView.insertSubview(view, aboveSubview: imageView)
        loadedVideoRenderView = view
    }

    /// Gives up the live surface so a hero flight can fly the *same* layer.
    ///
    /// Mirroring — attaching the player to a second `AVPlayerLayer` — cannot be
    /// seamless, because a freshly attached layer has no decoded frame and
    /// reports `isReadyForDisplay == false` for ~100ms. Measured. Moving the
    /// view that is already rendering has no such window: same layer, same
    /// player, same frame, just a different superview.
    ///
    /// The cell drops its reference; a later play builds a fresh surface.
    public func donateVideoRenderView() -> VideoRenderView? {
        guard let view = loadedVideoRenderView else { return nil }
        loadedVideoRenderView = nil
        view.removeFromSuperview()
        return view
    }

    /// Called when the collection view recycles this cell, so whoever loaned it
    /// a player takes it back. Mirrors `MapAnnotationView.onReuse`: a recycled
    /// cell that kept its player would render another post's video.
    public var onReuse: (() -> Void)?

    private let imageView = UIImageView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.postGridSystemFont(
        matching: .preferredFont(forTextStyle: .caption2), weight: .semibold
    )
    private let reactions = PostMetricLabel(
        symbol: "heart.fill", font: metaFont, color: .white, shadowed: true
    )
    private let views = PostMetricLabel(
        symbol: "eye.fill", font: metaFont, color: .white, shadowed: true
    )
    private var loadTask: Task<Void, Never>?

    override public init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.clipsToBounds = true
        // Soft bricks, not hard edges. `cornerRadius` re-applies this whenever
        // a host wants the softer pairing; the curve stays continuous either
        // way, which is what keeps a widened radius from reading as a stadium.
        contentView.layer.cornerRadius = cornerRadius
        contentView.layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.pin(to: contentView)

        // The badge sits over media of any brightness: a soft shadow instead
        // of a scrim keeps the thumbnail unobstructed.
        playBadge.tintColor = .white
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        playBadge.constrain(in: contentView) { parent in
            playBadge.topAnchor.constraint(equalTo: parent.topAnchor, constant: 8)
            playBadge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8)
        }

        // Views lead, reactions follow — reach first, then resonance.
        let counters = UIStackView(arrangedSubviews: [views, reactions])
        counters.axis = .horizontal
        counters.spacing = 8
        counters.constrain(in: contentView) { parent in
            counters.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8)
            counters.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -7)
            counters.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -8)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // A recycled cell must come back VISIBLE. A hero flight hides the tile
        // it is flying from, and that hide lives on the cell — so a cell
        // recycled while hidden carries the invisibility to whatever post it is
        // next bound to, and nothing on the reuse path would ever put it back.
        // One tile lost per flight whose cell got recycled before its unhide,
        // which is what made the gallery thin out over repeated round trips.
        isHidden = false
        alpha = 1
        // Hand the player back BEFORE anything else: a recycled cell that kept
        // its loan would show the previous post's video under the new post's
        // still. The coordinator clears its own bookkeeping in response.
        onReuse?()
        onReuse = nil
        onCoverLoaded = nil
        endVideoPreview()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
    }

    /// Puts a cover on the tile immediately, without waiting for the async load
    /// that is already in flight to come back.
    ///
    /// Closes a race the autoplay gate would otherwise lose: `configure` asks
    /// the cache once, and if the image lands *after* that (from the prefetch)
    /// the cache has it while this cell is still showing nothing. A gate that
    /// consulted the cache would pass, and the tile would start playing with a
    /// blank face anyway — which is the exact failure the gate exists to
    /// prevent.
    public func applyCover(_ image: UIImage) {
        guard imageView.image == nil else { return }
        imageView.image = image
        loadedVideoRenderView?.setPoster(image)
    }

    /// Fired when the cover lands from an async load.
    ///
    /// Autoplay is gated on the cover being present, and the gate is evaluated
    /// by a reconcile that normally only runs on scroll. Without this, a tile
    /// whose cover arrives while the grid is sitting still would fail the gate
    /// once and never be asked again — it would simply never play.
    public var onCoverLoaded: (() -> Void)?

    /// Reveals the video surface once a player has been attached. The still
    /// stays underneath as the poster, so the first frame replaces it rather
    /// than flashing black.
    public func beginVideoPreview() {
        let view = makeVideoRenderViewIfNeeded()
        view.setPoster(imageView.image)
        // The cover keeps the tile until there is video to replace it with.
        // Unhiding here put an empty surface over the cover for the whole
        // decode start-up — measured at ~1.2s on a cold tile — which is a tile
        // going dark at rest, before any transition is involved.
        view.revealOnFirstFrame()
        #if DEBUG
        // Whether the tile had a cover AT THE MOMENT playback started. Holding
        // the surface back is only worth anything if there is something behind
        // it; a nil here means the tile is black no matter what the renderer
        // does, and the fix belongs in the cover pipeline rather than here.
        if ProcessInfo.processInfo.arguments.contains("-avsbdl-log") {
            print(String(format: "[avsbdl] %.3f tile beginVideoPreview cover=%@",
                         CACurrentMediaTime(), imageView.image == nil ? "NIL" : "present"))
        }
        #endif
    }

    /// Back to a still tile.
    public func endVideoPreview() {
        // Faded, not switched off. This runs for every tile `beginHandoff`
        // stops as a flight leaves, and a binary hide snaps each of their
        // covers back in a single frame — several thumbnails popping at once,
        // on the grid, at exactly the moment the viewer is watching the flight.
        loadedVideoRenderView?.hideCrossFading()
    }

    public func configure(with post: GalleryPost, imagePipeline: ImagePipeline) {
        playBadge.isHidden = post.kind != .video
        // Video tiles keep a dark floor: their poster may be unrenderable
        // (or plain black in the simulator), and the glyph needs a stage.
        contentView.backgroundColor = post.kind == .video ? .darkGray : .secondarySystemBackground

        reactions.set(post.reactionCount)
        views.set(post.viewCount)

        imageView.image = nil
        guard let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            imageView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled else { return }
            guard let self else { return }
            UIView.transition(
                with: self.imageView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.imageView.image = image
            }
            // A tile can start playing before its cover arrives, and
            // `beginVideoPreview` reads the cover exactly once — so a cover
            // that lands afterwards never reached the surface, leaving it with
            // no poster to fall back on for the rest of its life. That is the
            // difference between a cold flight showing the thumbnail and
            // showing nothing.
            self.loadedVideoRenderView?.setPoster(image)
            self.onCoverLoaded?()
        }
    }
}

extension PostGridTileCell: GridPlaybackCell {}
