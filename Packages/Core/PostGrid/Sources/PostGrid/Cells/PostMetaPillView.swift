import DesignSystem
import UIKit

/// A pill carrying one run of a card's metadata OVER its media.
///
/// A row's metadata reads against the card's own fill, where `.secondaryLabel`
/// on `.secondarySystemBackground` is a settled pair. Moved onto a photo it has
/// no such ground: the same grey lands on whatever the image happens to be. The
/// answer is not a stronger shadow — the media tiles' counters take that route,
/// and it works there because they are two short numbers over a thumbnail
/// nobody is reading. A DATE is a word, and words need a floor.
///
/// So the pill brings one: `.systemMaterial`, which is defined PER INTERFACE
/// STYLE. Light chip in light mode, dark chip in dark mode, on every photo.
///
/// ## Two rejected grounds, and they fail in opposite directions
///
/// ❌ **An opaque near-black chip with white text**, argued from the play badge:
/// what is under a chip does not follow the interface style, so a chrome that
/// did would be wrong on half the photos in either mode. Sound, and still too
/// heavy — two solid slabs on the thing the card exists to show.
///
/// ❌ **`UIGlassEffect(style: .regular)`**, which is what the app floats its
/// chrome on everywhere else, and which looked like the answer to exactly that
/// objection: it resolves its own luminance against whatever passes under it,
/// so it never picks the wrong side. That property is a virtue for chrome over
/// a page and a defect for a chip on a photograph — the two chips on one card
/// resolve independently, so a bright sky and a dark cliff put a light chip and
/// a dark chip on the same image, and a chip changes side as the photo behind it
/// loads or a video plays. The app looks like it is switching theme by itself.
///
/// The rule the argument converged on: chrome over CONTENT the viewer is
/// reading follows the CONTENT; chrome over MEDIA follows the DEVICE, because
/// media has no side and the viewer's eye is already committed to one.
///
/// The shape is `cornerConfiguration`, never `layer.cornerRadius` — a material
/// clipped by a layer radius does not know it has been clipped, and its edge is
/// drawn on the shape it thinks it has.
///
/// Subclassable for one reason only: `MediaPageIndicatorView` is a third chip in
/// the same row and must stand on the same ground. Anything else that needs this
/// material should hold one rather than inherit it.
public class PostMetaPillView: UIVisualEffectView {
    /// The overlay type, shared with the media tiles' counters: a card's
    /// counters are footnote against the card and caption2 semibold over media,
    /// and this is the second of those two. `PostMetricLabel` names both.
    public static var font: UIFont {
        UIFont.postGridSystemFont(
            matching: .preferredFont(forTextStyle: .caption2), weight: .semibold
        )
    }

    /// `.label`, which resolves against the INTERFACE STYLE — the same authority
    /// the material now answers to, so the two can never disagree about which
    /// side they are on.
    ///
    /// `.label` rather than the closing line's `.secondaryLabel`: a material
    /// over a photograph is a busier ground than a card's flat fill, and this is
    /// the ground that has to carry a four-character count at caption2.
    ///
    /// Deliberately NOT a vibrancy effect. Vibrancy blends the glyphs into what
    /// is behind them, which is the same backdrop-following behaviour the
    /// material was just moved away from — it would put the defect back one
    /// layer up.
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
        // ⚠️ And the view has to CLIP to it, which glass did not need.
        //
        // `UIGlassEffect` draws its own shape, so a corner configuration alone
        // was enough while the chip was glass. A `UIBlurEffect` backdrop fills
        // the view's bounds and is clipped by the layer or not at all — so
        // swapping the effect silently turned every capsule back into a
        // rectangle, on screen only.
        //
        // The corner configuration was still correct throughout, which is the
        // part worth remembering: `effectiveRadius` resolved to half the height
        // and the test asserting it passed, because a resolved radius says the
        // shape was CONFIGURED, never that it was drawn. It took a 3x crop of a
        // screenshot to see it.
        clipsToBounds = true
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
        effect = Self.makeBackdrop()
    }

    /// The chip's ground, as a value rather than inline, so a test can ask what
    /// it is without a window — building the effect is cheap, ATTACHING one
    /// off-screen is what stalls a headless simulator.
    ///
    /// `.systemMaterial` rather than one of the thinner steps: the thinner a
    /// material is the more of the photo it lets through, and the closer it
    /// comes to the behaviour this deliberately moved away from — a light chip
    /// going grey over a dark image while its `.label` glyphs stay black.
    /// Regular holds the interface style's own tone.
    static func makeBackdrop() -> UIVisualEffect {
        UIBlurEffect(style: .systemMaterial)
    }
}
