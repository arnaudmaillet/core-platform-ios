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
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.pin(to: contentView)

        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 0
        captionLabel.constrain(in: card) { parent in
            captionLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 16)
            captionLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 16)
            captionLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16)
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
        metaRow.spacing = 14
        metaRow.constrain(in: card) { parent in
            metaRow.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 16)
            metaRow.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16)
            metaRow.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -14)
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
        }
    }
}

// MARK: - Media tile

/// One square of the Media grid: photo thumbnail, or video poster + badge,
/// with the compact counter pair (reactions, views) resting bottom-leading —
/// caption2 over a soft shadow, no scrim, so the preview stays the star.
public final class PostGridTileCell: UICollectionViewCell {
    public static let reuseID = "PostGridTileCell"

    /// The image the brick is currently showing — see `PostGridListRowCell`'s
    /// note for why a hero reads this rather than the image pipeline.
    public var renderedCover: UIImage? { imageView.image }

    /// The surface an autoplaying tile renders into, built on first use so a
    /// grid of stills never allocates a player layer it will not use.
    ///
    /// Not a `lazy var`: the coordinator needs to ask whether a cell *could* be
    /// playing (`loadedVideoRenderView`) without the question itself allocating
    /// the layer, which is exactly what touching a lazy var would do.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        if let loadedVideoRenderView { return loadedVideoRenderView }
        let view = VideoRenderView()
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
        // Soft mosaic bricks, not hard edges — matched to the list cards'
        // inner media rounding.
        contentView.layer.cornerRadius = 10
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
        // Hand the player back BEFORE anything else: a recycled cell that kept
        // its loan would show the previous post's video under the new post's
        // still. The coordinator clears its own bookkeeping in response.
        onReuse?()
        onReuse = nil
        endVideoPreview()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
    }

    /// Reveals the video surface once a player has been attached. The still
    /// stays underneath as the poster, so the first frame replaces it rather
    /// than flashing black.
    public func beginVideoPreview() {
        let view = makeVideoRenderViewIfNeeded()
        view.setPoster(imageView.image)
        view.isHidden = false
    }

    /// Back to a still tile.
    public func endVideoPreview() {
        loadedVideoRenderView?.isHidden = true
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
        }
    }
}
