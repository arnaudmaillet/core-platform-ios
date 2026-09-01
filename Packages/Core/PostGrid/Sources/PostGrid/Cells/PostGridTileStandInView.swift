import CoreModels
import CoreNavigation
import MediaCore
import UIKit

/// `RevealDismissCardView`'s GRID twin: one free-standing brick on its own
/// fill, for a close that lands on a tile.
///
/// ## Why a stand-in and not the flight card
///
/// A hero's flight card flies a cover it was HANDED — the departing cell's
/// rendered image — because that is the one thing a media hero can promise is
/// the same object at both ends. This is for the case where it is not: the
/// post the window lands on is a DIFFERENT one from the post that departed, so
/// there is no cover to hand over and the arrival has to fetch its own. A cell
/// already knows how (`PostGridTileCell.configure(with:imagePipeline:)` asks
/// the cache, then loads and cross-dissolves), which is why this holds a real
/// tile rather than an image view pretending to be one.
///
/// ## The two channels, and why they must never both carry content
///
/// The view is the tile's FILL and the tile is what it holds. Fading the two
/// independently is what gives a third state neither can give alone: a window
/// that is tile-coloured and holds nothing. `RevealTransition` states the law
/// that needs it — a fade only works against NOTHING, and blending two
/// pictures draws both — and `SnapFeedViewController.installRevealAuthorBand`
/// states it again for the band it draws into the page rather than fading in.
/// So `setContentOpacity` moves the TILE alone, `alpha` moves the fill, and a
/// caller can put a beat between them where the window holds neither picture.
public final class PostGridTileStandInView: UIView, RevealStandInShaping {
    private let tile: PostGridTileCell

    /// `size` is the LANDING CELL's — what the tile is built and configured at,
    /// so its cover is fetched for the right scale — but the tile then FILLS
    /// this view and travels with it.
    ///
    /// ⚠️ FILLED, NOT CENTRED, and this is where the tile parts company with
    /// `RevealDismissCardView`. That one centres a fixed-width card because
    /// stretching a card would re-wrap its CAPTION, and the extra width around
    /// it is fill on fill — invisible. A tile has no caption and its extra is
    /// not invisible at all: the window starts full-screen, so a brick pinned
    /// to the landing size sat as a small rectangle in the middle of a large
    /// grey one for most of the flight. Measured on video — a grey card with a
    /// postage stamp of the photograph inside it.
    ///
    /// Re-cropping every frame is the CORRECT behaviour here, not the thing to
    /// avoid: the cover is aspect-fill, and letting it recompute against the
    /// travelling bounds is what makes the morph continuous at any aspect —
    /// the same reasoning `ZoomFlightCard.zoomLiveMediaTracksCardBounds`
    /// already records for the flight card.
    ///
    /// `cornerRadius` is the page's, not the cell default: the two grids that
    /// share `PostGridTileCell` space their tiles differently, and gap and
    /// curve are one decision (see `ChaoticSliceLayout.harmonisedGutter`).
    public init(
        post: GalleryPost,
        size: CGSize,
        cornerRadius: CGFloat = PostGridTileCell.mosaicCornerRadius,
        imagePipeline: ImagePipeline
    ) {
        tile = PostGridTileCell(frame: CGRect(origin: .zero, size: size))
        super.init(frame: CGRect(origin: .zero, size: size))
        // The tile's OWN floor, so the empty beat is the colour the brick would
        // have shown anyway rather than a second opinion about it.
        backgroundColor = PostGridTileCell.fillColor(for: post)
        isUserInteractionEnabled = false

        tile.cornerRadius = cornerRadius
        tile.configure(with: post, imagePipeline: imagePipeline)
        tile.layoutIfNeeded()

        clipsToBounds = true
        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func layoutSubviews() {
        super.layoutSubviews()
        // The window's rounding, so the stand-in is the window's shape at every
        // size rather than a rectangle inside it.
        layer.cornerCurve = .continuous
    }

    /// The window's rounding, driven by the flight.
    ///
    /// Both layers, now that the tile fills this view: the tile clips its own
    /// cover, so a tile still wearing the landing radius would square off its
    /// picture inside a window that has already rounded.
    public func setCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
        tile.cornerRadius = radius
    }

    /// The TILE's opacity, separate from this view's own — see the note above
    /// for why the two channels exist and why neither may carry the other's
    /// content.
    public func setContentOpacity(_ alpha: CGFloat) {
        tile.alpha = alpha
    }
}
