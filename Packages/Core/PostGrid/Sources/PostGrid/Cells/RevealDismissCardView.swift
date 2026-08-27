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
public final class RevealDismissCardView: UIView, RevealStandInShaping {
    /// What the row's header is showing in its trailing pill.
    ///
    /// A value rather than three parameters, because the three are one answer:
    /// they are read together off one row and drawn together into one capsule,
    /// and a caller that got two of them from the row and the third from a
    /// habit is exactly the mismatch this exists to prevent.
    public struct BandActions: Sendable, Equatable {
        public var repost: Bool
        public var bookmark: Bool
        public var saved: Bool

        public init(repost: Bool, bookmark: Bool, saved: Bool) {
            self.repost = repost
            self.bookmark = bookmark
            self.saved = saved
        }

        /// A row whose host wired neither control — a profile gallery's, until
        /// it does.
        public static let none = BandActions(repost: false, bookmark: false, saved: false)
    }

    private let card: PostGridListRowCell

    /// `width` is the card's own, so the caption wraps and truncates exactly as
    /// the row does. Never the window's: the window is wider at the start of a
    /// flight and narrows as it lands, and a caption re-wrapping mid-flight is
    /// a reflow nobody asked for.
    ///
    /// `captionExpanded` is the other half of "exactly as the row does", and it
    /// is not optional in practice — it only carries a default so a caller with
    /// no expansion state at all can still build one. A row whose caption the
    /// viewer opened is TALLER and ends in the last word rather than in an
    /// ellipsis and a "Show more"; a stand-in built without that flies a
    /// truncated card home and lands it on an expanded one, which is a jump in
    /// both the text and the height.
    /// `showsAuthorMenu` is the same kind of answer as `captionExpanded`: what
    /// the ROW it stands in for is showing. The "..." is drawn but never wired
    /// — the stand-in takes no touches — and it must be drawn exactly when the
    /// landing row draws one. Both ways of being wrong are a jump in the last
    /// frame: absent here it pops in, present here it pops out, and the second
    /// is what shipped (a viewer's own post has no menu, so every dismissal on
    /// your own profile ended with a control vanishing).
    /// `height` is the ROW's own, when the caller has a realized one to ask.
    ///
    /// ⚠️ This is what keeps the card's CONTENT where the row's content is, and
    /// the reason is the centring below. The card is centred in the window, and
    /// the window lands on the row's rect — so if the card's height and the
    /// row's disagree by `d`, every line inside it lands `d/2` off, uniformly.
    /// The window can travel its whole trajectory and settle to the point (it
    /// does: measured, 331 frames, 0.0pt short) and the swap still jumps.
    ///
    /// Measuring the card independently invites that disagreement:
    /// `preferredLayoutAttributesFitting` answers for a freshly built cell,
    /// while the row's height is whatever the collection view's layout settled
    /// on. Asking the row removes the question. `nil` falls back to the fitted
    /// height, which is all a caller with no realized row can offer.
    public init(
        post: GalleryPost,
        width: CGFloat,
        imagePipeline: ImagePipeline,
        captionExpanded: Bool = false,
        showsAuthorMenu: Bool = true,
        actions: BandActions = .none,
        ageText: String? = nil,
        height: CGFloat? = nil
    ) {
        card = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        super.init(frame: .zero)
        backgroundColor = PostGridListRowCell.cardFillColor
        isUserInteractionEnabled = false

        card.configure(with: post, imagePipeline: imagePipeline, captionExpanded: captionExpanded)
        // Drawn but not wired, and only when the row has one — see the note on
        // the initialiser. A stand-in with no handlers would hide the control
        // by default, which is the wrong answer for the rows that do have it.
        if showsAuthorMenu {
            card.showAuthorMenuControlAsScenery()
        }
        // The header's trailing pill, on the same terms: drawn, never wired,
        // and only what the row itself is showing.
        card.showBandActionsAsScenery(
            repost: actions.repost, bookmark: actions.bookmark, saved: actions.saved
        )
        // ⚠️ THE ROW'S DATE, not this instant's. See
        // `PostGridListRowCell.renderedAgeText`: a compact age is a function of
        // the clock, and the row worked its own out when it was configured.
        if let ageText { card.overrideAgeText(ageText) }
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        // `preferredLayoutAttributesFitting` only ANSWERS with a height; a cell
        // left as built keeps its construction size, and every rect read off it
        // is that size rather than the row's.
        let fitted = card.preferredLayoutAttributesFitting(attributes)
        // The ROW's height wins whenever there is one to ask.
        let cardHeight = height ?? fitted.frame.height
        card.bounds.size = CGSize(width: width, height: cardHeight)
        card.layoutIfNeeded()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-text-reveal-log") {
            print("[text-reveal] standIn post=\(post.id.rawValue) w=\(width)"
                + " rowH=\(height.map { "\($0)" } ?? "-") fittedH=\(fitted.frame.height)"
                + " used=\(cardHeight) expanded=\(captionExpanded)")
        }
        #endif

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
            card.heightAnchor.constraint(equalToConstant: cardHeight)
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
    public func setCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
    }

    /// The CARD's opacity, separate from this view's own — which is what makes
    /// an empty state possible at all.
    ///
    /// The view is the card's FILL and the card is what it holds. Fading the
    /// two independently gives a third thing neither can give alone: a window
    /// that is card-coloured and holds nothing. See `RevealStage.swapToStandIn`
    /// for why that beat matters.
    public func setContentOpacity(_ alpha: CGFloat) {
        card.alpha = alpha
    }
}
