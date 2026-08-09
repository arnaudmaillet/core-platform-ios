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
        /// A grid brick: the layout's tile corners, counters and badge overlaid
        /// on the media.
        case tile
        /// The preview inside a timeline row: 12pt corners, and NO counters —
        /// that row shows its metrics in a line *below* the media, so overlaying
        /// them on the flight would conjure furniture the source never had.
        case listMedia
        /// A whole timeline row, for a TEXT post: the card's own 18pt corners
        /// and fill, carrying the caption.
        ///
        /// A text row has no media, so there is no part of it that is "the
        /// thing being opened" — the card IS the post. Without this such rows
        /// had no hero at all and fell back to a plain push, which is the one
        /// place in For You where opening a post did not fly.
        case listCard

        var cornerRadius: CGFloat {
            switch self {
            case .tile: PostGridFlightCard.tileCornerRadius
            case .listMedia: PostGridListRowCell.mediaCornerRadius
            case .listCard: PostGridListRowCell.cardCornerRadius
            }
        }

        var showsCounters: Bool { self == .tile }
        /// The card's ground before it becomes a page. A text card is the row's
        /// own fill; the media styles keep the floor their preview sits on.
        var fillsWithCardColor: Bool { self == .listCard }
        /// The play badge's inset, matched to each cell's own.
        var badgeInset: CGFloat {
            switch self {
            case .tile: 8
            case .listMedia: 10
            case .listCard: 10
            }
        }
    }

    /// Matches the rounding the For You grid gives its tiles, so the card is
    /// the brick's twin rather than its approximation.
    ///
    /// Sourced from the layout rather than restated as a literal: the card, the
    /// tile and the hoisted dismissal surface (`ForYouViewController`) all have
    /// to round identically, and three copies of one number is how they drift
    /// apart. Every flight this card serves departs from the For You grid — the
    /// profile gallery has no zoom source — so the chaotic layout's pairing is
    /// unconditionally the right one here.
    static let tileCornerRadius = ChaoticSliceLayout.harmonisedCornerRadius

    private let style: Style
    /// Whether a live surface has been adopted, tracked explicitly rather than
    /// inferred from `videoRenderView.isHidden`.
    ///
    /// `isHidden` used to carry both meanings at once, and they have since
    /// diverged: `VideoRenderView.revealOnFirstFrame()` keeps a surface hidden
    /// until it has a frame, so "hidden" now means "not ready YET" as well as
    /// "no media at all". Reading the flag for the second meaning made the card
    /// disown a surface it genuinely had — and `ZoomFlight` gates
    /// `prepareZoomLiveMediaForFlight` on this, which is what gives the surface
    /// its size. The card then flew a zero-sized layer over a dark background,
    /// which is a black frame at the moment the feed hands over.
    fileprivate var hasAdoptedLiveMedia = false
    private let imageView = UIImageView()
    /// The card's own surface, used when it has to mirror. Replaced by a
    /// donated one whenever the source can hand over the layer it is already
    /// rendering — see `adoptZoomLiveMediaView`.
    private(set) var videoRenderView: VideoRenderView = {
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "card"
        #endif
        return view
    }()
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
    /// Only populated for `.listCard` — a text row's words, standing in for
    /// the row while it flies.
    private let captionLabel = UILabel()
    /// Held so the caption can be re-placed onto the destination's own caption
    /// once the flight knows where that is.
    private var captionConstraints: [NSLayoutConstraint] = []

    init(post: GalleryPost, cover: UIImage?, style: Style) {
        self.style = style
        super.init(frame: .zero)
        clipsToBounds = true
        // Video bricks keep a dark floor, exactly as the tile cell does: the
        // poster may be unrenderable and the glyph needs a stage.
        backgroundColor = style.fillsWithCardColor
            ? PostGridListRowCell.cardFillColor
            : (post.kind == .video ? .darkGray : .secondarySystemBackground)
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

        // The CAPTION rides the resting chrome, which is the source's own
        // furniture and is what crossfades out as the destination's chrome
        // fades in. So the row's text is present at the tile end, dissolves
        // through the flight, and the page's own caption takes over — rather
        // than two captions being on screen at once, or the card flying empty.
        if style == .listCard {
            captionLabel.text = post.caption
            captionLabel.font = .preferredFont(forTextStyle: .body)
            captionLabel.adjustsFontForContentSizeCategory = true
            captionLabel.textColor = .label
            captionLabel.numberOfLines = 0
            captionLabel.translatesAutoresizingMaskIntoConstraints = false
            restingChromeView.addSubview(captionLabel)
            // The ROW's placement to begin with — correct at the source end,
            // and replaced by the destination's the moment the flight knows it
            // (`positionZoomCaption`).
            captionConstraints = [
                captionLabel.topAnchor.constraint(
                    equalTo: restingChromeView.topAnchor, constant: PostGridListRowCell.captionTopInset
                ),
                captionLabel.leadingAnchor.constraint(
                    equalTo: restingChromeView.leadingAnchor, constant: PostGridListRowCell.captionInset
                ),
                captionLabel.trailingAnchor.constraint(
                    equalTo: restingChromeView.trailingAnchor, constant: -PostGridListRowCell.captionInset
                ),
            ]
            NSLayoutConstraint.activate(captionConstraints)
            // …and the METRIC LINE, because the row hides whole for this
            // flight and the card is standing in for all of it. Carrying only
            // the caption left the counters and the age missing for the
            // length of the flight and popping back on its last frame — the
            // very artifact this style was added to remove, one level down.
            // Caught by frame-stepping the dismissal, not by reasoning.
            let meta = Self.makeListCardMetaRow(for: post)
            meta.constrain(in: restingChromeView) { parent in
                meta.leadingAnchor.constraint(
                    equalTo: parent.leadingAnchor, constant: PostGridListRowCell.captionInset
                )
                meta.trailingAnchor.constraint(
                    equalTo: parent.trailingAnchor, constant: -PostGridListRowCell.captionInset
                )
                meta.bottomAnchor.constraint(
                    equalTo: parent.bottomAnchor, constant: -PostGridListRowCell.metaBottomInset
                )
            }
        }

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

    /// Lands the caption on the destination's, so the page fading in
    /// underneath replaces it without anything moving. `frame` is in the
    /// card's page-pose coordinates, which is the space these constants live
    /// in — every pose after this scales the label with the card.
    func positionZoomCaption(at frame: CGRect) {
        guard style == .listCard, bounds.width > 0 else { return }
        NSLayoutConstraint.deactivate(captionConstraints)
        captionConstraints = [
            captionLabel.topAnchor.constraint(equalTo: restingChromeView.topAnchor, constant: frame.minY),
            captionLabel.leadingAnchor.constraint(equalTo: restingChromeView.leadingAnchor, constant: frame.minX),
            captionLabel.trailingAnchor.constraint(
                equalTo: restingChromeView.trailingAnchor, constant: frame.maxX - bounds.width
            ),
        ]
        NSLayoutConstraint.activate(captionConstraints)
        layoutIfNeeded()
    }

    /// The row's own closing line, rebuilt: views, reactions and comments
    /// leading, the compact age trailing — same order, same type, same colour,
    /// so the card is the row's twin rather than an approximation of it.
    private static func makeListCardMetaRow(for post: GalleryPost) -> UIStackView {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let views = PostMetricLabel(symbol: "eye", font: font, color: .secondaryLabel)
        let reactions = PostMetricLabel(symbol: "heart", font: font, color: .secondaryLabel)
        let comments = PostMetricLabel(symbol: "bubble.right", font: font, color: .secondaryLabel)
        views.set(post.viewCount)
        reactions.set(post.reactionCount)
        comments.set(post.commentCount)

        let age = UILabel()
        age.font = font
        age.textColor = .secondaryLabel
        age.adjustsFontForContentSizeCategory = true
        age.text = PostMetadata.compactAge(ofMillis: post.publishedAtMS)
        age.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let row = UIStackView(arrangedSubviews: [views, reactions, comments, spacer, age])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = PostGridListRowCell.metaSpacing
        return row
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

}

// MARK: - ZoomFlightCard

extension PostGridFlightCard: ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { style.cornerRadius }

    /// A text card carries the post's own caption, and the page it lands on
    /// shows that same caption. It rides the whole flight so the card is never
    /// empty while the page fades in over it.
    var zoomRestingChromeFadesOut: Bool { style != .listCard }

    var zoomRestingChrome: UIView? { restingChromeView }

    /// The live surface, but ONLY while this card still contains it.
    ///
    /// A dismissal hoists the surface out of the card and into a host above the
    /// navigation controller, and from that moment the host owns its geometry.
    /// Reporting it here anyway meant the flight kept posing it too: `poseAtSource`
    /// sets `center` in CARD-LOCAL coordinates, which for a ~130pt tile is about
    /// (65, 65) — the top-left of the SCREEN once the view lives in the host's
    /// space. That is the landscape media's jump to the left at frame 0.
    ///
    /// The two drivers also fought over the same layer: setting `frame` (the
    /// host) on a view with an in-flight `transform` animation (the card) is
    /// undefined, and it showed — a probe caught `position` AND `position-2`
    /// stacked on one layer, with `bounds` inflating 406->752 while the card
    /// was shrinking toward the tile.
    ///
    /// The invariant is the fix: a card poses only the media it actually holds.
    var zoomLiveMediaSurface: UIView? {
        guard hasAdoptedLiveMedia, videoRenderView.isDescendant(of: self) else { return nil }
        return videoRenderView
    }

    var zoomLiveMediaNativeSize: CGSize? { videoRenderView.nativeVideoSize }

    /// True when the card has no live media (the cover is the content and is
    /// always drawing), or when the live surface it adopted is genuinely
    /// visible and rendering. False is the interesting answer: it means the
    /// cover underneath is what the viewer is looking at.
    var zoomLiveMediaIsDrawing: Bool {
        hasAdoptedLiveMedia ? videoRenderView.isRenderingVisibly : true
    }

    var zoomLiveMediaDebugState: String {
        hasAdoptedLiveMedia ? videoRenderView.debugSurfaceState : "no live media"
    }

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
        insertSubview(view, aboveSubview: imageView)
        hasAdoptedLiveMedia = true
        // A card flying a surface that ALREADY HAS A FRAME must be
        // transparent beneath it. The surface's content rides outside the
        // CATransaction, so its first composite can lag its commit by a pass
        // — and an opaque cover or floor under it turns that pass into a
        // visible content blink: the stale cover drawn over the still-live
        // source (video → cover → video). Transparent, the same pass shows
        // the source THROUGH the card at the same rect — continuity instead
        // of a flash. A COLD surface keeps the cover: there is no video
        // anywhere yet, so the cover is the content, exactly as on a card
        // with no live media at all.
        if view.hasFrame {
            imageView.isHidden = true
            backgroundColor = .clear
        }
        // Not `isHidden = false`. On a cold flight this surface has no frame
        // yet, and showing it would replace the cover — the very pixels the
        // tile is displaying — with an empty surface for one decode interval.
        // The cover stays until there is real video to put over it.
        view.revealOnFirstFrame()
        #if DEBUG
        view.debugTracksFlight = true
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            // Full state at adopt. `frames=0` says it was never primed;
            // `hidden=Y frames>0` says something hid it after; anything else
            // points at a later detach.
            // Geometry too: a subview inserted with a zero frame renders at
            // the origin, which is what a ghost at the top-left corner is.
            print(String(format: "[zoom-live] %.3f card ADOPTED LIVE VIEW %@ cardBounds=%@ surfaceFrame=%@",
                         CACurrentMediaTime(), view.debugSurfaceState,
                         NSCoder.string(for: bounds), NSCoder.string(for: view.frame)))
        }
        #endif
    }

    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {
        guard mirror(videoRenderView) else { return }
        hasAdoptedLiveMedia = true
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
    /// FALSE: the surface is laid out once at destination size and driven by
    /// a uniform-scale transform, the same path the map pin uses.
    ///
    /// It was true, so the flight resized the surface's bounds instead. The
    /// surface's FRAME tracked the card perfectly under that — measured
    /// per-frame off the presentation layer — but an
    /// `AVSampleBufferDisplayLayer` does not re-render its video rect during an
    /// ANIMATED bounds change: inside a correctly sized, correctly centred
    /// surface the content stayed drawn at its previous size, pinned to the
    /// layer origin. On screen that is the media unveiling from its top-left
    /// corner rather than zooming, which is exactly what was reported.
    ///
    /// Core Animation DOES interpolate layer content under a transform, so the
    /// scale path renders smoothly at every intermediate size.
    ///
    /// **The trade this re-accepts.** A page-sized surface under a uniform
    /// scale renders the PAGE's crop whatever shape the card currently is:
    /// against a 402x874 page a 2:1 landscape brick shows only 22.9% of the
    /// surface vertically. That is why this was flipped to true originally.
    /// `PostGridSliceArrangement` keeps that crop small by placing each clip in
    /// the block whose aspect is nearest its media, so the flight travels the
    /// page's own aspect — which is what makes this affordable again.
    ///
    /// The chaotic layout narrows the range this has to survive as well as
    /// matching within it: BSP blocks are scored toward 3:4 … 4:3, so there is
    /// no 2:1 brick left to produce the worst case above. The trade is that
    /// there is no 1:2 brick either, so a 9:16 clip cannot be matched as tightly
    /// as the old mosaic matched it — verify takeoff on portrait video before
    /// trusting this comment.
    var zoomLiveMediaTracksCardBounds: Bool { false }

    /// Lays the surface out ONCE at destination size, with autoresizing off so
    /// nothing else moves it. The flight owns its transform and centre from
    /// here; the layer's bounds never change again, which is what keeps the
    /// content rendering smoothly across the morph.
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        videoRenderView.transform = .identity
        videoRenderView.autoresizingMask = []
        videoRenderView.bounds = CGRect(origin: .zero, size: destinationSize)
    }

    // `applyZoomRestingShadow` is left at its default no-op: mosaic bricks rest
    // flat against their neighbours with only a hairline gutter between them,
    // so a drop shadow at the source end would appear from nowhere. The pin
    // needs one because it floats above a map; this does not.
}
