import CoreModels
import DesignSystem
import EmoteKit
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
///
/// ## ⚠️ Laid out ONCE, at the card's size — then posed, never re-laid out
///
/// A copy that rides a transition window is resized every frame of it, from
/// the card to the whole screen and back. Laid out against those sizes the
/// way a cell lays out, the caption re-wrapped at every width, and whatever
/// pass ran first ran inside the flight's animation block: every label grew
/// out of the window's top-left corner towards its place, the whole length
/// of a close. Filmed on a Following video card and on text cards alike — "the
/// text appears from the top-left and extends to the bottom-right, as if it
/// were not anchored".
///
/// So a copy is built with its `referenceSize` — the card's resting size —
/// and wraps its words there, exactly as the card in the row does. At any
/// other size each piece keeps that layout and is POSED, by a uniform scale of
/// the window's width to the card's, onto the edge it belongs to: the foot for
/// a picture's author and caption, the top for a text card's words, the foot
/// for its author. The window's corners carry them from the first frame, and
/// only the fade the flight gives the whole overlay changes what is seen —
/// the arrangement the flight already gives the page's chrome replica, laid
/// out once and scaled into the card.
///
/// The cell's own overlay passes no reference: it IS the card, and lays out
/// at whatever size the card is, like any view.
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

    /// The scrim, as a VIEW: a bare sublayer's frame does not ride a UIKit
    /// animation block, so a scrim posed inside one jumped to its landing
    /// rect while the window it belongs to was still travelling.
    private let scrim = ScrimView()
    private let authorLabel = UILabel()
    /// An `EmoteLabel`: the caption's emoji and `:code:` emotes animate on the
    /// card as they do on the list's cards (`PostGridListRowCell`), and only
    /// while the card is actually on screen (`EmoteVisibility`).
    private let captionLabel = EmoteLabel()
    private let placement: Placement
    /// The size the words are wrapped at — see the note on this type. Nil:
    /// whatever size the overlay is.
    private let referenceSize: CGSize?
    /// The layout at the reference size, kept so a pose re-derives it only
    /// when the reference itself changes (the cell's, as the card resizes).
    private var restingLayout: RestingLayout?
    /// Whether the pieces have been posed at all. The first pose is never
    /// animated, whoever's block it lands in: a label with no frame yet would
    /// grow into its place out of a zero rect — the unfold this type exists to
    /// end.
    private var hasPosed = false

    init(post: GalleryPost, placement: Placement, referenceSize: CGSize? = nil) {
        self.placement = placement
        let reference = referenceSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        self.referenceSize = reference
        super.init(frame: CGRect(origin: .zero, size: reference ?? .zero))
        isUserInteractionEnabled = false
        let onMedia = placement == .onMedia
        scrim.isHidden = !onMedia
        addSubview(scrim)
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

    /// Where each piece sits on a card of `size`, in that card's space.
    private struct RestingLayout {
        let size: CGSize
        let caption: CGRect
        let author: CGRect
        /// The scrim's top edge; it always runs to the card's foot.
        let scrimTop: CGFloat
    }

    private func restingLayout(for size: CGSize) -> RestingLayout {
        let inset = Self.inset
        let width = max(0, size.width - inset * 2)
        let authorHeight = authorLabel.font.lineHeight.rounded(.up)
        let fitted = captionLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height.rounded(.up)
        switch placement {
        case .onMedia:
            // From the foot up: the caption's two lines, the author above them.
            let caption = CGRect(
                x: inset, y: size.height - inset - fitted, width: width, height: fitted
            )
            let author = CGRect(
                x: inset, y: caption.minY - 2 - authorHeight, width: width, height: authorHeight
            )
            // The scrim reaches a little above the author, so the text never
            // sits on the picture's own brightness.
            return RestingLayout(
                size: size, caption: caption, author: author, scrimTop: max(0, author.minY - 36)
            )
        case .onCard:
            // The words from the top, the author at the foot.
            let author = CGRect(
                x: inset, y: size.height - inset - authorHeight, width: width, height: authorHeight
            )
            let available = author.minY - inset * 2
            let caption = CGRect(
                x: inset, y: inset + 2, width: width, height: min(fitted, max(0, available))
            )
            return RestingLayout(size: size, caption: caption, author: author, scrimTop: size.height)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let reference = referenceSize ?? bounds.size
        if restingLayout?.size != reference {
            restingLayout = restingLayout(for: reference)
        }
        guard let resting = restingLayout, resting.size.width > 0 else { return }
        if hasPosed {
            pose(resting)
        } else {
            hasPosed = true
            UIView.performWithoutAnimation { pose(resting) }
        }
    }

    /// Every piece at its resting layout, scaled by the window's width over
    /// the card's and pinned to the edge it belongs to — which is exactly the
    /// resting layout when the overlay is the card's own size.
    ///
    /// By `bounds`/`center`/`transform`, never `frame`: a label keeps the
    /// bounds it wrapped its words in, so nothing re-wraps and nothing is
    /// redrawn stretched. Only where a piece is and how large it is drawn
    /// move, and both ride whatever animation block is posing the window.
    private func pose(_ resting: RestingLayout) {
        let scale = bounds.width / resting.size.width
        func fromFoot(_ y: CGFloat) -> CGFloat { bounds.height - (resting.size.height - y) * scale }
        func place(_ view: UIView, _ rect: CGRect, atFoot: Bool) {
            view.bounds = CGRect(origin: .zero, size: rect.size)
            view.center = CGPoint(
                x: rect.midX * scale, y: atFoot ? fromFoot(rect.midY) : rect.midY * scale
            )
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        switch placement {
        case .onMedia:
            place(captionLabel, resting.caption, atFoot: true)
            place(authorLabel, resting.author, atFoot: true)
            let top = fromFoot(resting.scrimTop)
            scrim.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        case .onCard:
            place(captionLabel, resting.caption, atFoot: false)
            place(authorLabel, resting.author, atFoot: true)
        }
    }

    /// The scrim: a gradient that rides its view's animated frame.
    private final class ScrimView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            guard let gradient = layer as? CAGradientLayer else { return }
            gradient.colors = [
                UIColor.black.withAlphaComponent(0).cgColor,
                UIColor.black.withAlphaComponent(0.35).cgColor,
                UIColor.black.withAlphaComponent(0.72).cgColor
            ]
            gradient.locations = [0, 0.45, 1]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    #if DEBUG
    /// Where the words are drawn, in this overlay's space — the anchoring a
    /// suite pins.
    var debugCaptionFrame: CGRect { captionLabel.frame }
    var debugAuthorFrame: CGRect { authorLabel.frame }
    /// The width the caption is wrapped at — the card's, never the window's.
    var debugCaptionWrapWidth: CGFloat { captionLabel.bounds.width }
    #endif
}

/// One card in For You's Following row: a post, equal-sized with its
/// neighbours, playing (muted) whenever it is half on screen, with its first
/// two lines over the bottom of it.
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
        // No press feedback — see `ForYouStoryCell`: a tap opens, a long press
        // lifts the native preview.
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
    ///
    /// ⚠️ BUILT AT THE CARD'S SIZE AND LAID OUT NOW, outside any animation.
    /// The flight resizes it every frame from here on; a copy that met its
    /// first layout pass inside the flight's block grew out of the window's
    /// top-left corner. `restingSize` nil (the card is not in its row) keeps
    /// the overlay laying out at whatever size it is given, as before.
    static func makeOverlay(for post: GalleryPost, restingSize: CGSize?) -> ForYouCardCaptionOverlay {
        let overlay = ForYouCardCaptionOverlay(
            post: post, placement: post.kind == .text ? .onCard : .onMedia, referenceSize: restingSize
        )
        UIView.performWithoutAnimation { overlay.layoutIfNeeded() }
        return overlay
    }

    /// The card as it rests, drawn fresh at `size` — what a window opening from
    /// it starts as and a close lands on, whatever kind of post it is.
    ///
    /// ⚠️ A MEDIA CARD CLOSES AS A WINDOW TOO. It opens with a flight, but the
    /// feed is a pager: page from its photograph onto a TEXT post and there is
    /// no picture left to fly, so the close is the card-shaped window
    /// (`RowCardCloseLanding`) — and what that window lands as has to be this
    /// card, picture and caption, not a text card that never sat in the row.
    /// `cover` is the picture the card was showing; nil draws its floor.
    static func makeStandIn(for post: GalleryPost, cover: UIImage?, size: CGSize) -> UIView {
        guard post.kind != .text else { return makeTextStandIn(for: post, size: size) }
        let card = UIView(frame: CGRect(origin: .zero, size: size))
        card.backgroundColor = PostGridTileCell.fillColor(for: post)
        card.layer.cornerRadius = cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        let picture = UIImageView(frame: card.bounds)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.image = cover
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(picture)
        addAnchoredOverlay(for: post, placement: .onMedia, to: card)
        return card
    }

    /// A text card, drawn fresh at `size` — what a window opening from this
    /// card starts as and a close lands on.
    static func makeTextStandIn(for post: GalleryPost, size: CGSize) -> UIView {
        let card = UIView(frame: CGRect(origin: .zero, size: size))
        card.backgroundColor = PostGridListRowCell.cardFillColor
        card.layer.cornerRadius = cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        addAnchoredOverlay(for: post, placement: .onCard, to: card)
        return card
    }

    /// The caption a stand-in wears, pinned to all four of its edges and
    /// wrapped at the card's own size — see `ForYouCardCaptionOverlay`.
    ///
    /// ⚠️ LAID OUT HERE, at the card's size and outside any animation. The
    /// reveal resizes a stand-in with the window and lays it out inside its
    /// own block (`RevealStage.apply`); a caption meeting its FIRST pass there
    /// grew out of the window's top-left corner for the whole close — the
    /// text cards' half of the defect the flight's overlay had. From here on
    /// every pass only re-poses what this one wrapped.
    private static func addAnchoredOverlay(
        for post: GalleryPost, placement: ForYouCardCaptionOverlay.Placement, to card: UIView
    ) {
        let overlay = ForYouCardCaptionOverlay(
            post: post, placement: placement, referenceSize: card.bounds.size
        )
        overlay.frame = card.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(overlay)
        UIView.performWithoutAnimation { card.layoutIfNeeded() }
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
