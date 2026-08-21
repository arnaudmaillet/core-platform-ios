import DesignSystem
import UIKit

/// A pill of glass carrying one run of a card's metadata OVER its media.
///
/// A row's metadata reads against the card's own fill, where `.secondaryLabel`
/// on `.secondarySystemBackground` is a settled pair. Moved onto a photo it has
/// no such ground: the same grey lands on whatever the image happens to be. The
/// answer is not a stronger shadow — the media tiles' counters take that route,
/// and it works there because they are two short numbers over a thumbnail
/// nobody is reading. A DATE is a word, and words need a floor.
///
/// So the pill brings one, and the floor is the system's `.regular` glass — the
/// material this app already floats its chrome on, from the toast to the
/// comment strip. It resolves its own luminance against whatever passes under
/// it, which is what lets the numbers ride `.label` and track both appearances
/// without a hand-picked colour on either side.
///
/// ❌ The first version was an opaque near-black chip with white text, argued
/// from the play badge: what is under it does not follow the interface style,
/// so a chrome that did would be wrong on half the photos in either mode. The
/// argument was sound and the result was still too heavy — two solid slabs on
/// a preview that is the reason the card exists. Glass answers the same
/// objection differently: it does not pick a side, it takes the photo's.
///
/// The shape is `cornerConfiguration`, never `layer.cornerRadius` — a material
/// clipped by a layer radius does not know it has been clipped, and its
/// specular edge is drawn on the shape it thinks it has.
public final class PostMetaPillView: UIVisualEffectView {
    /// The overlay type, shared with the media tiles' counters: a card's
    /// counters are footnote against the card and caption2 semibold over media,
    /// and this is the second of those two. `PostMetricLabel` names both.
    public static var font: UIFont {
        UIFont.postGridSystemFont(
            matching: .preferredFont(forTextStyle: .caption2), weight: .semibold
        )
    }

    /// Adaptive, over an adaptive material — the toast's rule. `.label` rather
    /// than the closing line's `.secondaryLabel`: glass over a photograph is a
    /// busier ground than a card's flat fill, and this is the ground that has to
    /// carry a four-character count at caption2.
    public static let foreground: UIColor = .label

    /// The pill's inner padding — tight, because it rests on a preview and is
    /// furniture rather than content.
    public static let insets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

    private let contents: [UIView]

    public init(contents: [UIView], spacing: CGFloat = 8) {
        self.contents = contents
        super.init(effect: nil)
        // A capsule, and `.capsule()` rather than a number: the ends have to
        // stay circular at whatever height Dynamic Type resolves to, and a fixed
        // radius stops being half of that at the first step.
        //
        // It is allowed to be a capsule because of where its HOST puts it, not
        // because capsules were preferred. A chip inside its parent's corner arc
        // owes that corner a concentric radius, and inside a 10pt preview arc
        // the arithmetic answers 2 — a rectangle. A chip held clear of the arc
        // meets straight edge on both sides, has no band to hold, and is free.
        // `PostGridListRowCell.mediaFurnitureInset` is what buys that clearance,
        // and a test asserts it, because this shape is standing on it.
        cornerConfiguration = .capsule()
        // Furniture, never a target. The card's own tap opens the post, and a
        // chip that swallowed touches would put two dead corners on the preview.
        isUserInteractionEnabled = false
        let row = UIStackView(arrangedSubviews: contents)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = spacing
        row.pin(to: contentView, insets: Self.insets)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Hides the pill when every one of its contents is hidden.
    ///
    /// The counters hide themselves when the post has no number to show —
    /// absence, not an asserted zero — so a pill that tracked its own PRESENCE
    /// rather than its contents' ANSWER would draw an empty capsule on the
    /// photo. It is the mistake the author band's "..." made, in the one place
    /// where the leftover is a filled shape rather than a glyph.
    public func syncVisibilityToContents() {
        isHidden = contents.allSatisfy(\.isHidden)
    }

    /// Materialized on window attach, never in init: building a real effect
    /// off-screen contacts the render server and stalls the main actor for tens
    /// of seconds on a headless CI simulator. It is the rule `ToastView`,
    /// `SnapGlassCardView` and `ChatInputBar` all follow, and it matters more
    /// here than for any of them — these are cells, so the alternative is that
    /// cost once per row rather than once per screen.
    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, effect == nil else { return }
        let glass = UIGlassEffect(style: .regular)
        // Not a touch target, so it must not flex under a finger.
        glass.isInteractive = false
        effect = glass
    }
}
