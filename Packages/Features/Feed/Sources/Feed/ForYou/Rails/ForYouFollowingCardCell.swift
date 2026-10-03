import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The bottom of a Following card — who posted, and the first two lines of
/// what they said. The overlay lives in PostGrid since the mosaic's large
/// tiles wear it too (`PostCardCaptionOverlay`); this is
/// the name the Following card has always called it by.
typealias ForYouCardCaptionOverlay = PostCardCaptionOverlay

/// One MEDIA card in For You's Following row (its top lane,
/// `ForYouFollowingLanes`) and in Discover's pairs: a photo or a video,
/// equal-sized with its neighbours, playing (muted) whenever it is half on
/// screen, with its author and first two lines over the bottom of it.
///
/// A mosaic brick's twin in everything the playback and the flight ask
/// (`GridPlaybackCell`, like `PostGridTileCell`): a cover image, a video
/// surface built on first use above it, the cover kept as the poster until the
/// first frame, and the surface handed back on reuse. What it adds is the
/// overlay.
///
/// Media only, since 3 October 2026: a text post in the Following row is the
/// list's own card (`PostGridListRowCell`) in the bottom lane, and the text
/// face this card used to draw — its words on the card's fill — is gone, with
/// its stand-in. Pairs are vertical media by construction.
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
        contentView.backgroundColor = PostGridTileCell.fillColor(for: post)
        // Its like reads the viewer's stake once a host binds the card
        // (`PostCardStaking.bindReadout`); unstaked until then.
        let overlay = ForYouCardCaptionOverlay(
            post: post, placement: .onMedia, imagePipeline: imagePipeline, viewerStake: 0
        )
        contentView.addSubview(overlay)
        overlay.frame = contentView.bounds
        self.overlay = overlay
        accessibilityLabel = [post.authorName, post.caption].compactMap { $0 }.joined(separator: ", ")

        imageView.image = nil
        guard let url = post.thumbnailURL else { return }
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

    // MARK: - The like

    /// What the viewer has staked on the card's post — the heart closing the
    /// author line turns red (`PostCardStaking.bindReadout`). A readout: the
    /// card has no control on it, and a tap anywhere opens the post.
    func setViewerStake(_ total: Int) {
        overlay?.setViewerStake(total)
    }

    #if DEBUG
    /// The heart closing the card's author line.
    var debugLikeReadout: PostLikeReadoutView? { overlay?.likeReadout }
    #endif

    /// The flight carries a copy of the overlay as its resting furniture —
    /// see `ForYouCardCaptionOverlay`.
    ///
    /// ⚠️ BUILT AT THE CARD'S SIZE AND LAID OUT NOW, outside any animation.
    /// The flight resizes it every frame from here on; a copy that met its
    /// first layout pass inside the flight's block grew out of the window's
    /// top-left corner. `restingSize` nil (the card is not in its row) keeps
    /// the overlay laying out at whatever size it is given, as before.
    ///
    /// `viewerStake`: what the card's heart is drawn with — red when there
    /// is any, as on the card (`ForYouCardCaptionOverlay`).
    static func makeOverlay(
        for post: GalleryPost, restingSize: CGSize?, imagePipeline: ImagePipeline? = nil,
        viewerStake: Int = 0
    ) -> ForYouCardCaptionOverlay {
        let overlay = ForYouCardCaptionOverlay(
            post: post, placement: .onMedia, referenceSize: restingSize,
            imagePipeline: imagePipeline, viewerStake: viewerStake
        )
        UIView.performWithoutAnimation { overlay.layoutIfNeeded() }
        return overlay
    }

    /// The card as it rests, drawn fresh at `size` — what a close lands on.
    ///
    /// ⚠️ A MEDIA CARD CLOSES AS A WINDOW TOO. It opens with a flight, but the
    /// feed is a pager: page from its photograph onto a TEXT post and there is
    /// no picture left to fly, so the close is the card-shaped window
    /// (`RowCardCloseLanding`) — and what that window lands as has to be this
    /// card, picture and caption, not a text card that never sat in the row.
    /// `cover` is the picture the card was showing; nil draws its floor.
    /// `viewerStake`: what the card's heart is drawn with, as on the card.
    static func makeStandIn(
        for post: GalleryPost, cover: UIImage?, size: CGSize, imagePipeline: ImagePipeline? = nil,
        viewerStake: Int = 0
    ) -> UIView {
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
        addAnchoredOverlay(for: post, to: card, imagePipeline: imagePipeline, viewerStake: viewerStake)
        return card
    }

    /// The caption a stand-in wears, pinned to all four of its edges and
    /// wrapped at the card's own size — see `ForYouCardCaptionOverlay`.
    ///
    /// ⚠️ LAID OUT HERE, at the card's size and outside any animation. The
    /// reveal resizes a stand-in with the window and lays it out inside its
    /// own block (`RevealStage.apply`); a caption meeting its FIRST pass there
    /// grew out of the window's top-left corner for the whole close — the
    /// same defect the flight's overlay had. From here on every pass only
    /// re-poses what this one wrapped.
    private static func addAnchoredOverlay(
        for post: GalleryPost, to card: UIView, imagePipeline: ImagePipeline?, viewerStake: Int
    ) {
        let overlay = ForYouCardCaptionOverlay(
            post: post, placement: .onMedia, referenceSize: card.bounds.size,
            imagePipeline: imagePipeline, viewerStake: viewerStake
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

extension ForYouFollowingCardCell: PostCardLikeReadout {}
