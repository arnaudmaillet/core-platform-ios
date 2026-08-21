import CoreModels
import MediaCore
import CoreNavigation
import PostGrid
import UIKit

/// What a reveal's window carries HOME: the card itself, not the page.
///
/// ## The scroll that broke the first design
///
/// The reveal's premise was that the page IS the hero — nothing impersonates
/// anything, the real destination is masked and the mask sweeps. That holds
/// exactly as long as the page still shows, at the same place, what the card
/// shows. Scrolling the comments ends it: the caption moves, often off screen
/// entirely, and the window then flies home carrying comment rows and swaps for
/// the caption in its final frame.
///
/// It cannot be patched by aligning harder. Bringing a caption back from 800pt
/// above the viewport means translating the page 800pt during the close — the
/// whole stream rushing across the screen, the viewer's reading position thrown
/// away in front of them. A correct implementation of that idea is still a bad
/// animation. The boundary is the design's, not the code's.
///
/// So the DISMISS impersonates and the present does not, and the asymmetry
/// answers an asymmetric fact: a page is always at rest when it opens and may
/// be anywhere when it closes. The five text-hero attempts that died of
/// impersonation all died on the PRESENT, where a stand-in had to grow into a
/// live, self-sizing, safe-area-owning page and stay in step with it. Here the
/// target is a static card, there is nothing to keep in step, and a stand-in is
/// simply the right representation — which is what the media hero has always
/// done.
///
/// ## What it draws
///
/// The card at its own natural size, CENTRED in the window, on the card's
/// own fill. The window is larger than the card for most of a flight and
/// the fill covers the difference — the same silhouette the veil used to make,
/// which is why the swap reads as nothing changing when the page is unscrolled:
/// the caption is the same words in the same place. The correction only shows
/// itself when there was something to correct.
final class RevealDismissCardView: UIView, RevealStandInShaping {
    private let card: PostGridListRowCell

    /// `width` is the card's own, so the caption wraps and truncates exactly as
    /// the row does. Never the window's: the window is wider at the start of a
    /// flight and narrows as it lands, and a caption re-wrapping mid-flight is
    /// a reflow nobody asked for.
    init(post: GalleryPost, width: CGFloat, imagePipeline: ImagePipeline) {
        card = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        super.init(frame: .zero)
        backgroundColor = PostGridListRowCell.cardFillColor
        isUserInteractionEnabled = false

        card.configure(with: post, imagePipeline: imagePipeline)
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        // `preferredLayoutAttributesFitting` only ANSWERS with a height; a cell
        // left as built keeps its construction size, and every rect read off it
        // is that size rather than the row's.
        let fitted = card.preferredLayoutAttributesFitting(attributes)
        card.bounds.size = CGSize(width: width, height: fitted.frame.height)
        card.layoutIfNeeded()

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            // CENTRED, not pinned to the edges: the window is up to a section
            // inset wider than the card at the start of a flight, and stretching
            // the card to meet it would re-wrap the caption. Centred, the extra
            // width is fill on fill and cannot be seen.
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            // CENTRED vertically too, and that is not symmetry for its own
            // sake. Pinned to the top, the card appeared at the top of a
            // full-screen window while the page kept showing underneath it —
            // two things in one window, one of them nowhere near where the
            // viewer was looking. Centred, it materialises under the finger and
            // the window closes onto it; at the landing the window IS the card
            // and centred and pinned are the same thing.
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: width),
            card.heightAnchor.constraint(equalToConstant: fitted.frame.height)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The window's rounding, so the stand-in is the window's shape at every
        // size rather than a rectangle inside it.
        layer.cornerCurve = .continuous
    }

    /// The window's rounding, driven by the flight.
    func setCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
    }

    /// The CARD's opacity, separate from this view's own — which is what makes
    /// an empty state possible at all.
    ///
    /// The view is the card's FILL and the card is what it holds. Fading the
    /// two independently gives a third thing neither can give alone: a window
    /// that is card-coloured and holds nothing. See `RevealStage.swapToStandIn`
    /// for why that beat matters.
    func setContentOpacity(_ alpha: CGFloat) {
        card.alpha = alpha
    }
}
