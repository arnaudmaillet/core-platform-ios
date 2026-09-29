import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The bottom of a Following card: who posted, and the first two lines of what
/// they said — over a scrim on a picture, straight on the card for words.
///
/// Its own view, not a few labels inside the cell, because a flight needs a
/// COPY of it: the card that flies out of the row wears this as its resting
/// furniture and the flight fades it as the card grows into the page, the way
/// a mosaic brick's counters leave (`SnapFeedHeroOrigin.restingOverlay`).
final class ForYouCardCaptionOverlay: UIView {
    enum Placement {
        /// Over media: white text on a dark scrim rising from the foot.
        case onMedia
        /// A text post: the card IS the words, so no scrim, and the caption
        /// takes the whole card rather than two lines of it.
        case onCard
    }

    /// Two lines over a picture — the product call: enough to know what the
    /// post is about, not so much that the picture is covered.
    static let mediaCaptionLines = 2
    /// A text card's words fill it.
    static let textCaptionLines = 7

    private let scrim = CAGradientLayer()
    private let authorLabel = UILabel()
    private let captionLabel = UILabel()
    private let placement: Placement

    init(post: GalleryPost, placement: Placement) {
        self.placement = placement
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        let onMedia = placement == .onMedia
        if onMedia {
            scrim.colors = [
                UIColor.black.withAlphaComponent(0).cgColor,
                UIColor.black.withAlphaComponent(0.35).cgColor,
                UIColor.black.withAlphaComponent(0.72).cgColor
            ]
            scrim.locations = [0, 0.45, 1]
            layer.addSublayer(scrim)
        }
        authorLabel.font = .systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold
        )
        authorLabel.textColor = onMedia ? .white : .secondaryLabel
        authorLabel.text = post.authorName ?? post.authorHandle.map { "@\($0)" }
        captionLabel.font = onMedia
            ? .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .medium)
            : .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold)
        captionLabel.textColor = onMedia ? .white : .label
        captionLabel.numberOfLines = onMedia ? Self.mediaCaptionLines : Self.textCaptionLines
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.text = post.caption
        for label in [authorLabel, captionLabel] where onMedia {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.35
            label.layer.shadowRadius = 2
            label.layer.shadowOffset = .zero
        }
        addSubview(captionLabel)
        addSubview(authorLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let inset: CGFloat = 10

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.inset
        let width = max(0, bounds.width - inset * 2)
        let authorHeight = authorLabel.font.lineHeight.rounded(.up)
        switch placement {
        case .onMedia:
            // From the foot up: the caption's two lines, the author above them.
            let captionHeight = captionLabel.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height.rounded(.up)
            captionLabel.frame = CGRect(
                x: inset, y: bounds.height - inset - captionHeight,
                width: width, height: captionHeight
            )
            authorLabel.frame = CGRect(
                x: inset, y: captionLabel.frame.minY - 2 - authorHeight,
                width: width, height: authorHeight
            )
            // The scrim reaches a little above the author, so the text never
            // sits on the picture's own brightness.
            let scrimTop = max(0, authorLabel.frame.minY - 36)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrim.frame = CGRect(x: 0, y: scrimTop, width: bounds.width, height: bounds.height - scrimTop)
            CATransaction.commit()
        case .onCard:
            // The words from the top, the author at the foot.
            authorLabel.frame = CGRect(
                x: inset, y: bounds.height - inset - authorHeight,
                width: width, height: authorHeight
            )
            let available = authorLabel.frame.minY - inset * 2
            let fitted = captionLabel.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height.rounded(.up)
            captionLabel.frame = CGRect(
                x: inset, y: inset + 2, width: width, height: min(fitted, max(0, available))
            )
        }
    }
}

/// One card in For You's Following row: a post, equal-sized with its
/// neighbours, playing when it is the row's lead, with its first two lines
/// over the bottom of it.
///
/// A mosaic brick's twin in everything the playback and the flight ask
/// (`GridPlaybackCell`, like `PostGridTileCell`): a cover image, a video
/// surface built on first use above it, the cover kept as the poster until the
/// first frame, and the surface handed back on reuse. What it adds is the
/// overlay, and a TEXT post's own face — the card is its words.
final class ForYouFollowingCardCell: UICollectionViewCell {
    static let reuseID = "ForYouFollowingCardCell"

    /// The rounding a card takes: the timeline row's MEDIA corner, so the
    /// flight out of it can be the list's own card style (`.listMedia`) and
    /// land on the same curve it left.
    static var cornerRadius: CGFloat { PostGridListRowCell.mediaCornerRadius }

    private let imageView = UIImageView()
    private var overlay: ForYouCardCaptionOverlay?
    private var loadTask: Task<Void, Never>?
    private(set) var post: GalleryPost?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = Self.cornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.backgroundColor = PostGridListRowCell.cardFillColor
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.pin(to: contentView)
        isAccessibilityElement = true
        accessibilityTraits = .button
        PressFeedback.attach(toView: contentView, dims: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Visible again, whatever a flight left: a hide lives on the cell, and
        // a recycled one would carry it to its next post.
        isHidden = false
        onReuse?()
        onReuse = nil
        onCoverLoaded = nil
        endVideoPreview()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
        overlay?.removeFromSuperview()
        overlay = nil
        post = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay?.frame = contentView.bounds
    }

    func configure(with post: GalleryPost, imagePipeline: ImagePipeline) {
        self.post = post
        let isText = post.kind == .text
        contentView.backgroundColor = isText
            ? PostGridListRowCell.cardFillColor
            : PostGridTileCell.fillColor(for: post)
        let overlay = ForYouCardCaptionOverlay(post: post, placement: isText ? .onCard : .onMedia)
        contentView.addSubview(overlay)
        overlay.frame = contentView.bounds
        self.overlay = overlay
        accessibilityLabel = [post.authorName, post.caption].compactMap { $0 }.joined(separator: ", ")

        imageView.image = nil
        guard !isText, let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            imageView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled,
                  let self, self.post?.id == post.id else { return }
            UIView.transition(
                with: imageView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) { self.imageView.image = image }
            loadedVideoRenderView?.setPoster(image)
            onCoverLoaded?()
        }
    }

    /// The flight carries a copy of the overlay as its resting furniture —
    /// see `ForYouCardCaptionOverlay`.
    static func makeOverlay(for post: GalleryPost) -> ForYouCardCaptionOverlay {
        ForYouCardCaptionOverlay(post: post, placement: post.kind == .text ? .onCard : .onMedia)
    }

    /// A text card, drawn fresh at `size` — what a window opening from this
    /// card starts as and a close lands on.
    static func makeTextStandIn(for post: GalleryPost, size: CGSize) -> UIView {
        let card = UIView(frame: CGRect(origin: .zero, size: size))
        card.backgroundColor = PostGridListRowCell.cardFillColor
        card.layer.cornerRadius = cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        let overlay = ForYouCardCaptionOverlay(post: post, placement: .onCard)
        overlay.frame = card.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(overlay)
        return card
    }

    // MARK: - GridPlaybackCell

    var onCoverLoaded: (() -> Void)?
    var onReuse: (() -> Void)?
    private(set) var loadedVideoRenderView: VideoRenderView?

    var renderedCover: UIImage? { imageView.image }
    /// The card IS its media, edge to edge.
    var videoMediaRect: CGRect { bounds }
    var isRenderingCurrentMedia: Bool { loadedVideoRenderView != nil }

    func applyCover(_ image: UIImage) {
        guard imageView.image == nil else { return }
        imageView.image = image
        loadedVideoRenderView?.setPoster(image)
    }

    func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        if let loadedVideoRenderView { return loadedVideoRenderView }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "rail-card"
        #endif
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Above the still, BELOW the overlay: the words read over moving video
        // exactly as they do over a poster.
        contentView.insertSubview(view, aboveSubview: imageView)
        loadedVideoRenderView = view
        return view
    }

    func adoptVideoRenderView(_ view: VideoRenderView) {
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

    func donateVideoRenderView() -> VideoRenderView? {
        guard let view = loadedVideoRenderView else { return nil }
        loadedVideoRenderView = nil
        view.removeFromSuperview()
        return view
    }

    func beginVideoPreview() {
        let view = makeVideoRenderViewIfNeeded()
        view.setPoster(imageView.image)
        // The cover keeps the card until there is a frame to replace it with.
        view.revealOnFirstFrame()
    }

    func endVideoPreview() {
        loadedVideoRenderView?.hideCrossFading()
    }
}

extension ForYouFollowingCardCell: GridPlaybackCell {}
