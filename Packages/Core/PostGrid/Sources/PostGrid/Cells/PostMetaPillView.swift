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
/// So the pill brings one: a `UIBlurEffect` material, which is defined PER
/// INTERFACE STYLE. Light chip in light mode, dark chip in dark mode, on every
/// photo. Which STEP of material is a separate question, settled at
/// `makeBackdrop`.
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
    /// FOOTNOTE semibold, sized as a control rather than as a caption.
    ///
    /// ⚠️ It was caption2, matching the media tiles' counters, and that was the
    /// right register for a readout. These chips are becoming BUTTONS — a like
    /// you can press, a comment count that opens the thread — and 11pt type in
    /// 4pt of padding made a 21pt chip: half the 44pt a control owes a finger,
    /// and small enough to read as a label rather than as something to press.
    ///
    /// The tiles' counters stay caption2 deliberately. They are still readouts
    /// on a thumbnail nobody presses, so the two registers now say something —
    /// caption2 for what you read, footnote for what you touch.
    public static var font: UIFont {
        UIFont.postGridSystemFont(
            matching: .preferredFont(forTextStyle: .footnote), weight: .semibold
        )
    }

    /// The smallest square a control may be touched at. Apple's number, and the
    /// reason the padding below is what it is.
    public static let minimumTouchTarget: CGFloat = 44

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

    /// And `.secondaryLabel` for a GLYPH, which is the answer to "why is the
    /// header's pill a different colour from the ones at the bottom".
    ///
    /// It was, and the fix is not to make them agree on one ink. Inside a chip
    /// the number is the DATUM and the glyph NAMES it — a heart is a label for
    /// "160", not a second fact — so the pair reads correctly only when the two
    /// are ranked. Once they are, the band's control cluster, which is glyphs
    /// and nothing else, sits at exactly the same level as every other glyph on
    /// the card, and the card has one rule instead of two accidents: text
    /// carries the value, symbols stay quiet.
    ///
    /// It also protects the hierarchy the alternative would have broken —
    /// promoting the cluster to `.label` would have put three near-black marks
    /// beside a `.label` author name.
    public static let glyphForeground: UIColor = .secondaryLabel

    /// The pill's inner padding.
    ///
    /// Sized so a chip lands around 32pt tall — big enough to read as a control
    /// and to be hit comfortably, without four 44pt slabs lying across a
    /// photograph. The last 12pt to the touch target come from `point(inside:)`
    /// below rather than from more chrome.
    public static let insets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)

    /// ⚠️ THE ONE HEIGHT EVERY PILL ON A CARD IS.
    ///
    /// The card wears pills of two kinds now — counters and a date sized by
    /// their text, and the band's control cluster sized by three glyphs — and
    /// "the same height" has to be a fact rather than a coincidence of what
    /// happens to be inside them. So the height is DECLARED here, from the
    /// type's own line height, and every pill is constrained to it.
    ///
    /// Derived from the font rather than written as a number so Dynamic Type
    /// moves all of them together; `ceil` so the whole row lands on the same
    /// fraction of a point instead of two that differ by a rounding.
    public static var height: CGFloat {
        ceil(font.lineHeight) + insets.top + insets.bottom
    }

    private let contents: [UIView]

    /// - Parameter insets: the inner padding, defaulting to the text pills'.
    ///   A pill of ICONS overrides it: 12pt of padding is what a word needs to
    ///   sit off a capsule's ends, and a glyph button already carries its own,
    ///   so reusing it would push the cluster apart and swell the capsule past
    ///   the identity beside it.
    public init(
        contents: [UIView], spacing: CGFloat = 8,
        insets: NSDirectionalEdgeInsets = PostMetaPillView.insets
    ) {
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
        row.pin(to: contentView, insets: insets)
        contentRow = row
        // 999, not required: the pin above is required, so a content taller than
        // the declared height would be an unsatisfiable pair. This way the row
        // sizes to its contents in that case and logs nothing — the shape
        // degrades, the layout does not break.
        let uniform = heightAnchor.constraint(equalToConstant: Self.height)
        uniform.priority = .init(999)
        uniform.isActive = true
    }

    /// The chip's contents, so an animation can move them independently of the
    /// capsule around them.
    ///
    /// ⚠️ The two moving together reads as one object sliding, which is what a
    /// capsule and its label look like when both are animated by the same
    /// transform. Letting the contents lag by a few points is what makes the
    /// shape feel like a container the text is settling INTO.
    private(set) weak var contentRow: UIView?

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Extends the touch area to `minimumTouchTarget` without growing the chip.
    ///
    /// A 32pt chip is the right SIZE on a photograph and the wrong TARGET for a
    /// finger. Apple's own controls resolve that the same way: the drawn shape
    /// stays small and the hit region is grown around it. Inert while
    /// `isUserInteractionEnabled` is false — hit-testing never asks a view that
    /// takes no touches — so the counters carry it dormant until they become
    /// the buttons they are being sized for.
    override public func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let slopX = max((Self.minimumTouchTarget - bounds.width) / 2, 0)
        let slopY = max((Self.minimumTouchTarget - bounds.height) / 2, 0)
        return bounds.insetBy(dx: -slopX, dy: -slopY).contains(point)
    }

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
        effect = makeGround()
    }

    /// The pill's ground, chosen by the pill.
    ///
    /// ⚠️ A MATERIAL IS ONLY A GROUND WHERE THERE IS SOMETHING UNDER IT.
    ///
    /// `.systemMaterial` over a photograph is a light chip on a dark sea. Over
    /// the CARD's own fill it resolves to very nearly that fill — the capsule is
    /// drawn, correctly, in the colour of what it is standing on, and is
    /// invisible. Which is not a bug in the material: it is the rule this class
    /// was built on, read the other way. Chrome over MEDIA follows the device;
    /// chrome over CONTENT follows the content, and on a card that means a
    /// system FILL, not a blur of a flat colour.
    ///
    /// So a pill that stands on the card returns nil here and paints itself.
    /// Overridable rather than a stored parameter because the choice is a
    /// property of WHERE the pill is, which its class already says.
    public func makeGround() -> UIVisualEffect? {
        Self.makeBackdrop()
    }

    /// The chip's ground, as a value rather than inline, so a test can ask what
    /// it is without a window — building the effect is cheap, ATTACHING one
    /// off-screen is what stalls a headless simulator.
    ///
    /// ⚠️ `.systemThin`, ONE STEP DOWN FROM REGULAR — and the step was argued
    /// the other way first.
    ///
    /// The case against thinning: the thinner a material is the more of the
    /// photo it lets through, and the closer it comes to the behaviour this
    /// class exists to avoid — a light chip going grey over a dark image while
    /// its `.label` glyphs stay black.
    ///
    /// What that argument missed is that the CARD is not the post screen. Here
    /// four chips lie along the bottom of a preview a few hundred points tall,
    /// and at regular they read as four frosted slabs: the chip stops being a
    /// floor under a number and becomes an object competing with the picture.
    /// Thin still resolves per interface style, still holds its own tone, and
    /// is one step — not two. Ultra-thin is where the chip genuinely starts
    /// taking the photo's side, and that is the line.
    ///
    /// The property being traded is OPACITY, not authority: what makes this
    /// safe is the same thing that made regular safe, that a `UIBlurEffect`
    /// style is defined per interface style while a glass lens samples what
    /// passes under it.
    static func makeBackdrop() -> UIVisualEffect {
        UIBlurEffect(style: .systemThinMaterial)
    }
}

/// A pill that stands on the CARD's own fill rather than on media.
///
/// ⚠️ Same shape, same height, DIFFERENT GROUND — and the difference is not a
/// preference.
///
/// `PostMetaPillView`'s material resolves against what is behind it, which is
/// what makes it a floor over a photograph and what makes it nothing over a
/// flat colour: laid on the card it resolves to the card and the capsule is
/// drawn, correctly, invisible. A system FILL is a translucent overlay instead,
/// so it stands off the card by the same amount in either appearance.
///
/// ⚠️ `.tertiarySystemFill`, and the step was walked in both directions.
///
/// Measured on a real card, whose fill reads 242 in light mode:
///
/// | fill        | capsule | delta |
/// |-------------|---------|-------|
/// | secondary   |   222   |  20   |
/// | tertiary    |   227   |  15   |
/// | quaternary  |   232   |  10   |
///
/// Secondary was chosen first and was right at the time: the card carried ONE
/// filled capsule — the band's control cluster — and a lone container has to
/// assert itself. The closing line then gained two more, and three capsules of
/// the same fill weigh more than one of them did, so the same delta that read
/// as "a container" started reading as three grey slabs on a quiet card.
///
/// Quaternary is a step too far in the other direction: at a delta of 10 the
/// capsule stops being a shape and becomes a smudge behind a number.
///
/// The number that matters is the DELTA, not the token — which is why it is
/// recorded here. Change the card's fill and this choice needs re-measuring,
/// not re-reading.
///
/// ❌ Painting an opaque white behind the material so it has something to blur
/// was tried and rejected. It works, but a material over an opaque layer you
/// control is just a colour — it reduces to `.systemBackground`, which is white
/// on the card in light mode and BLACK on it in dark, so the contrast flips
/// direction between appearances.
public class PostCardPillView: PostMetaPillView {
    override public init(
        contents: [UIView], spacing: CGFloat = 8,
        insets: NSDirectionalEdgeInsets = PostMetaPillView.insets
    ) {
        super.init(contents: contents, spacing: spacing, insets: insets)
        contentView.backgroundColor = .tertiarySystemFill
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Nothing to resolve: the ground above is painted, not sampled.
    override public func makeGround() -> UIVisualEffect? { nil }
}

/// A chip's BOX without a chip's ground.
///
/// The preview's date sits in the same slot as the capsules beside it — same
/// height, same inner padding, so the row keeps one rhythm and every constraint
/// that measured against the date still measures the same thing — but draws no
/// capsule of its own. A capsule is a claim that what is inside it can be
/// pressed, and of the four things on that row the date is the one that never
/// will be.
///
/// Its floor comes from `ProgressiveMaterialView` behind it instead: the same
/// material, with no edge.
public final class PostChipSlotView: UIView {
    public init(contents: [UIView], spacing: CGFloat = 8) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        let row = UIStackView(arrangedSubviews: contents)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = spacing
        row.pin(to: self, insets: PostMetaPillView.insets)
        let uniform = heightAnchor.constraint(equalToConstant: PostMetaPillView.height)
        uniform.priority = .init(999)
        uniform.isActive = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
