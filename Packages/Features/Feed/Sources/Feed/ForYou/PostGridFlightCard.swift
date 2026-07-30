import CoreNavigation
import MediaPlayback
import PostGrid
import UIKit

/// The For You grid's hero card: what a mosaic brick looks like, as a
/// free-standing view the transition can fly.
///
/// The map pin can hand the hero its *actual* face (`PinCardView` is both the
/// pin and the card). A grid tile can't — its face is a `UICollectionViewCell`
/// the collection view owns and recycles — so this is a deliberate twin, and it
/// only stays a twin because it borrows the same constants from `PostGrid`
/// rather than restating them: the brick's 10pt continuous rounding, and the
/// counter overlay's glyphs, font and inset.
///
/// Layer order (bottom → top): cover image, live video surface, resting chrome
/// (counters + play badge). The flight fades the resting chrome out as the card
/// leaves the grid and back in as it returns, so a landed brick never pops its
/// furniture on.
final class PostGridFlightCard: UIView {
    /// Which surface the card is impersonating. The two pages present media
    /// differently, and a hero that flew from both with one set of constants
    /// would be a twin of neither.
    enum Style {
        /// A mosaic brick: 10pt corners, counters and badge overlaid on the media.
        case tile
        /// The preview inside a timeline row: 12pt corners, and NO counters —
        /// that row shows its metrics in a line *below* the media, so overlaying
        /// them on the flight would conjure furniture the source never had.
        case listMedia

        var cornerRadius: CGFloat {
            switch self {
            case .tile: PostGridFlightCard.tileCornerRadius
            case .listMedia: PostGridListRowCell.mediaCornerRadius
            }
        }

        var showsCounters: Bool { self == .tile }
        /// The play badge's inset, matched to each cell's own.
        var badgeInset: CGFloat {
            switch self {
            case .tile: 8
            case .listMedia: 10
            }
        }
    }

    /// Matches `PostGridTileCell`'s brick rounding.
    static let tileCornerRadius: CGFloat = 10

    private let style: Style
    private let imageView = UIImageView()
    /// The card's own surface, used when it has to mirror. Replaced by a
    /// donated one whenever the source can hand over the layer it is already
    /// rendering — see `adoptZoomLiveMediaView`.
    private(set) var videoRenderView = VideoRenderView()
    /// The tile's furniture: the counter pair and the play badge, in one view
    /// so the flight can fade them as a unit.
    private let restingChromeView = UIView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.systemFont(
        ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold
    )
    private let reactions = PostMetricLabel(
        symbol: "heart.fill", font: metaFont, color: .white, shadowed: true
    )
    private let views = PostMetricLabel(
        symbol: "eye.fill", font: metaFont, color: .white, shadowed: true
    )

    init(post: GalleryPost, cover: UIImage?, style: Style) {
        self.style = style
        super.init(frame: .zero)
        clipsToBounds = true
        // Video bricks keep a dark floor, exactly as the tile cell does: the
        // poster may be unrenderable and the glyph needs a stage.
        backgroundColor = post.kind == .video ? .darkGray : .secondarySystemBackground
        layer.cornerRadius = style.cornerRadius
        layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.image = cover
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)

        videoRenderView.frame = bounds
        videoRenderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoRenderView.clipsToBounds = true
        videoRenderView.isHidden = true
        addSubview(videoRenderView)

        restingChromeView.isUserInteractionEnabled = false
        restingChromeView.frame = bounds
        restingChromeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(restingChromeView)

        playBadge.tintColor = .white
        playBadge.isHidden = post.kind != .video
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        playBadge.constrain(in: restingChromeView) { parent in
            playBadge.topAnchor.constraint(equalTo: parent.topAnchor, constant: style.badgeInset)
            playBadge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -style.badgeInset)
        }

        guard style.showsCounters else { return }
        reactions.set(post.reactionCount)
        views.set(post.viewCount)
        let counters = UIStackView(arrangedSubviews: [views, reactions])
        counters.axis = .horizontal
        counters.spacing = 8
        counters.constrain(in: restingChromeView) { parent in
            counters.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8)
            counters.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -7)
            counters.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -8)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - ZoomFlightCard

extension PostGridFlightCard: ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { style.cornerRadius }

    var zoomRestingChrome: UIView? { restingChromeView }

    var zoomLiveMediaSurface: UIView? { videoRenderView.isHidden ? nil : videoRenderView }

    /// A grid tile never previews live, so this only ever fires on the dismiss
    /// leg — the feed's playing page mirrors its player here, and the card
    /// carries the live video home instead of a frozen cover.
    /// Takes ownership of a surface that is ALREADY rendering, swapping it in
    /// for the card's own.
    ///
    /// Preferred over `adoptZoomLiveMedia`, and the difference is the whole
    /// point: mirroring builds a second `AVPlayerLayer`, which has no decoded
    /// frame and stays `isReadyForDisplay == false` for ~100ms, so the card
    /// shows its static poster while the source is already hidden. Adopting the
    /// live view moves the layer that is mid-playback, so frame 0 of the flight
    /// is a real video frame.
    ///
    /// No poster is set here: the surface is already showing video, and a
    /// poster would only be a chance to flash.
    func adoptZoomLiveMediaView(_ view: UIView) {
        guard let view = view as? VideoRenderView else { return }
        videoRenderView.removeFromSuperview()
        videoRenderView = view
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.clipsToBounds = true
        view.isHidden = false
        insertSubview(view, aboveSubview: imageView)
        #if DEBUG
        view.debugLabel = "card(donated)"
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f card ADOPTED LIVE VIEW readyNow=%@",
                         CACurrentMediaTime(), view.isReadyForDisplay ? "true" : "false"))
        }
        #endif
    }

    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {
        #if DEBUG
        videoRenderView.debugLabel = "card"
        #endif
        guard mirror(videoRenderView) else { return }
        videoRenderView.setPoster(imageView.image)
        videoRenderView.isHidden = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f card attached readyNow=%@",
                         CACurrentMediaTime(), videoRenderView.isReadyForDisplay ? "true" : "false"))
        }
        #endif
    }

    func setZoomCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
    }

    /// The surface fills the card and resizes with it, so `resizeAspectFill`
    /// recomputes the crop on every frame of the morph.
    ///
    /// This replaces a page-sized surface driven by a uniform scale. That
    /// approach renders the PAGE's crop no matter what shape the card currently
    /// is: against a 402x874 page, a 2:1 landscape brick showed only 22.9% of
    /// the surface vertically, so takeoff jumped from the tile's wide
    /// aspect-fill to a thin band of a page-shaped video. A 1:2 portrait brick
    /// showed 92.3% and looked fine — which is why the jump read as
    /// landscape-only.
    var zoomLiveMediaTracksCardBounds: Bool { true }

    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        videoRenderView.transform = .identity
        videoRenderView.frame = bounds
        videoRenderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    // `applyZoomRestingShadow` is left at its default no-op: mosaic bricks rest
    // flat against their neighbours with only a hairline gutter between them,
    // so a drop shadow at the source end would appear from nowhere. The pin
    // needs one because it floats above a map; this does not.
}
