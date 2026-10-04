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
            matching: .appFont(forTextStyle: .footnote), weight: .semibold
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
    ///
    /// ⚠️ NOT the closing line's rule: its four actions draw glyph AND count
    /// in one ink, `PostCardPillView.ink`, and no action outranks another by
    /// colour. See that constant for why.
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
        // ⚠️ FURNITURE UNTIL SOMETHING ASKS OTHERWISE — see `setTapHandler`.
        //
        // The card's own tap opens the post, so a chip that swallowed touches
        // for nothing would put dead corners on the preview. A chip that has
        // somewhere to send them is a different thing, and turns this back on
        // for itself.
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

    /// Makes the pill a control, or furniture again with nil.
    ///
    /// ⚠️ **THE CARD'S ONE ACTION COMPONENT, NOT THIS CHIP'S OWN.** The chip
    /// used to wire a tap recogniser and a press of its own, and the comment
    /// chip of a TEXT post was left with neither — reported from a device as
    /// a button that "does nothing". `ActionAffordance` is the shared answer
    /// for every chip on a card: the press, a contrast step inside the
    /// capsule, a hold that freezes the screen until the lift, and — through
    /// `setMenuProvider` — a menu. Its tap swallows the touch, so pressing a
    /// chip never also opens the post under it.
    ///
    /// The chip is 32pt tall and `point(inside:)` already grows its target to
    /// 44, so this inherits a finger-sized region without the capsule growing
    /// to match.
    public func setTapHandler(_ handler: (() -> Void)?) {
        tapHandler = handler
        if handler != nil {
            ActionAffordance.attach(to: self, washingIn: contentView) { [weak self] in
                self?.tapHandler?()
            }
        }
        // After the attach, which turns interaction on: a chip with nothing
        // to do is furniture again, and its recognisers go dormant with it.
        isUserInteractionEnabled = handler != nil
        isAccessibilityElement = handler != nil
    }

    /// A menu raised by holding the chip — nil for none. Only meaningful on a
    /// chip that is a control (`setTapHandler`).
    public func setMenuProvider(_ provider: (() -> UIMenu?)?) {
        ActionAffordance.attached(to: self)?.menuProvider = provider
    }

    private var tapHandler: (() -> Void)?

    #if DEBUG
    /// Fires whatever the chip is wired to, for a simulator that injects no
    /// touches. Reports whether there was anything to fire — "the chip did
    /// nothing" and "the chip is not a control" are different answers.
    public func debugTap() -> Bool {
        guard let tapHandler else { return false }
        tapHandler()
        return true
    }
    #endif

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
    /// `SnapGlassCardView` and `CommentsInputBar` all follow, and it matters more
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

extension UIView {
    /// Whether this view and every ancestor up to its cell are actually shown.
    ///
    /// ⚠️ `isHidden` on the view itself is not the question. Both comment chips
    /// exist on every row; which one is SHOWN is decided by hiding a container
    /// several levels up — the media box or the closing line — so a chip can be
    /// perfectly visible in its own right and part of a branch nobody sees.
    var superviewChainIsVisible: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha == 0 { return false }
            view = current.superview
        }
        return true
    }
}

/// A card ACTION — comments, likes, repost, save — standing on the card's own
/// fill with NO GROUND OF ITS OWN.
///
/// ⚠️ PLAIN SINCE 30 SEPTEMBER 2026, and the name is the history. These wore a
/// `.tertiarySystemFill` capsule, four of them along the foot of every card,
/// and the card read as a row of grey slabs under its own content. Asked for
/// without containers: the actions are ink on the card, like the band's "..."
/// above them always was.
///
/// What stays of the capsule is its BOX, and every part of it still works:
/// - the declared height (`PostMetaPillView.height`), so the line keeps one
///   rhythm with the page indicator's capsule beside it;
/// - the press region, grown to 44pt by `point(inside:)`;
/// - the SHAPE the press draws. `ActionAffordance`'s wash is a capsule inside
///   this box, so a pressed action shows a capsule that was not there a moment
///   before and a held one a deeper one — the container appears only while a
///   finger is on it, the way the system's plain buttons answer a press.
///
/// ⚠️ **ONE INK FOR THE WHOLE LINE** (`ink`) — glyphs and counts, primary
/// actions and secondary ones. See `ink` for the two-rank version it replaced.
///
/// ⚠️ The padding shrank with the ground (`plainInsets`, 8 rather than 12): 12
/// was what a WORD needs to sit off a capsule's ends, and with no capsule to
/// sit off it only pushed the ink away from the caption column. The closing
/// line hangs its first and last box outward by their `inkLeading` /
/// `inkTrailing`, so the INK — not an invisible box — lines up on the line's
/// column (`PostGridListRowCell.actionLineInset`, one of these paddings
/// inside the caption's).
public class PostCardPillView: PostMetaPillView {
    /// The ink of every action on a card: `.secondaryLabel`, for the glyphs
    /// and for the counts beside them. A staked heart is the one exception,
    /// and it is the points' red (`PointsSymbol.tint`), not a darker grey.
    ///
    /// ⚠️ THERE WERE TWO RANKS (30 September – 1 October 2026): comments and
    /// likes in `.label`, glyph and count alike, repost and save in
    /// `.secondaryLabel`. On the card it read too dark — a semibold `.label`
    /// count is the same ink as the author's name and the caption, so the two
    /// counters competed with the post's own words, and the line's two halves
    /// looked like two different components rather than one row of verbs.
    ///
    /// The rank did not need the colour. The primary pair is still the
    /// heavier one: it is the only one carrying a NUMBER, so each of its
    /// boxes is a glyph plus a semibold count against a lone glyph; it holds
    /// the trailing end, where the eye finishes the line; and the like turns
    /// red the moment the viewer stakes. Apple's own action rows rank the same
    /// way: Photos' bar (share, favourite, info, delete) and Mail's toolbar
    /// draw every action in ONE tint, and the favourite heart says "yours" by
    /// filling, not by a darker shade at rest — fill, a badge or a count do
    /// the ranking, never two greys a step apart.
    ///
    /// ❌ Rejected: an intermediate grey (`.label` at ~75%). It is a THIRD
    /// grey on a card that already has `.label` (name, caption) and
    /// `.secondaryLabel` (handle, date), it leaves the semantic scale — so
    /// Increase Contrast would no longer darken it unless re-derived by hand —
    /// and beside `.secondaryLabel` glyphs a step away it reads as a rendering
    /// accident, not as a decision.
    ///
    /// Same ink as the band's "..." (`glyphForeground`), the handle and the
    /// closing date: the card has two inks, words in `.label` and everything
    /// around them in `.secondaryLabel`.
    public static let ink: UIColor = .secondaryLabel

    /// A plain action's padding: enough for the press wash to read as a
    /// capsule around the ink, and no more — see the type's note.
    public static let plainInsets = NSDirectionalEdgeInsets(
        top: PostMetaPillView.insets.top, leading: 8,
        bottom: PostMetaPillView.insets.bottom, trailing: 8
    )

    private let padding: NSDirectionalEdgeInsets

    override public init(
        contents: [UIView], spacing: CGFloat = 8,
        insets: NSDirectionalEdgeInsets = PostCardPillView.plainInsets
    ) {
        padding = insets
        super.init(contents: contents, spacing: spacing, insets: insets)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Nothing to resolve and nothing to paint: a plain action has no ground.
    override public func makeGround() -> UIVisualEffect? { nil }

    /// How far in from the box's leading edge the ink starts — what a line
    /// hangs this box out by to put the ink on its column.
    var inkLeading: CGFloat { padding.leading }

    /// The same, from the trailing edge.
    var inkTrailing: CGFloat { padding.trailing }
}

/// A plain action that is ONE GLYPH — the closing line's repost and save.
///
/// Interaction is ON, which is the one thing every other `PostMetaPillView` on
/// a card turns off by default — the counters become controls only when the
/// host gives them something to do. This one exists to be pressed.
public final class PostActionPillView: PostCardPillView {
    /// The width of the band's "..." — a glyph button carrying its own margin
    /// inside its width, hung from the card's top-right corner.
    public static let controlWidth: CGFloat = 36

    /// The width of a glyph action on the closing line: the glyph and a few
    /// points either side, which is what the press wash needs to read as a
    /// disc around it. 36 was sized to sit inside a capsule's ends; with no
    /// capsule it left ~12pt of air before the ink, and the save glyph sat
    /// visibly right of the caption it closes. `point(inside:)` grows the
    /// press region back to 44 either way.
    public static let plainControlWidth: CGFloat = 28

    override public init(
        contents: [UIView], spacing: CGFloat = 8,
        insets: NSDirectionalEdgeInsets = PostCardPillView.plainInsets
    ) {
        super.init(contents: contents, spacing: spacing, insets: insets)
        isUserInteractionEnabled = true
    }

    /// A plain action around exactly one glyph control, which fills it.
    public convenience init(control: UIView) {
        self.init(contents: [control], spacing: 0, insets: .zero)
        glyphControl = control
        // ⚠️ THE PILL IS THE CONTROL, the glyph inside is its face.
        //
        // The button used to answer its own events with the pill giving
        // around it, while the counter chips beside it ran a different
        // recogniser and a different press. Every action on the card goes
        // through `ActionAffordance` instead (see `setTapHandler`), so this
        // one forwards its tap to the button's own actions — the host's
        // target-action wiring is untouched — and the button stops taking
        // touches, so there is exactly one owner of the finger.
        if let control = control as? UIControl {
            control.isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityLabel = control.accessibilityLabel
            ActionAffordance.attach(to: self, washingIn: contentView) { [weak control] in
                control?.sendActions(for: .touchUpInside)
            }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private weak var glyphControl: UIView?

    /// ⚠️ A LONE GLYPH IS SIZED TO ITS BOX, NOT TO THE CARD'S TYPE.
    ///
    /// Two wrong answers were tried first, in opposite directions. A `UIButton`
    /// sizes a symbol from its own font — body, 17pt — which crowds a box the
    /// height of a footnote. Matching the counters' font instead, so every
    /// glyph on the card would be drawn at one size, produced glyphs that LOOK
    /// smaller than the counters' — measured, the heart beside "160" is 9pt of
    /// ink, a lone bookmark at that size 13pt: bigger, and reading as smaller,
    /// because a glyph alone is read against the space around it. UIKit's own
    /// bar buttons settle this at a little over half their container.
    public static var glyphPointSize: CGFloat {
        (PostMetaPillView.height * 0.58).rounded()
    }

    /// One configuration for every glyph control on a card.
    ///
    /// Zero content insets, rather than padding a glyph out to size: the width
    /// is set by a constraint, so insets would only fight it. `.medium`
    /// weight, one step up from regular and deliberately not two: regular
    /// reads thin, semibold empties the repost arrows into a blob. In the
    /// card's one action ink (`PostCardPillView.ink`): the band's "..." and
    /// the closing line's repost and save never outrank the name above them.
    public static func glyphConfiguration(systemName: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemName)
        configuration.baseForegroundColor = PostCardPillView.ink
        configuration.contentInsets = .zero
        configuration.preferredSymbolConfigurationForImage = glyphSymbolConfiguration
        return configuration
    }

    /// The symbol configuration every glyph control on a card is drawn at —
    /// the same size and weight the counters' glyphs take through
    /// `PostMetricLabel`'s `glyphPointSize`.
    static var glyphSymbolConfiguration: UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .medium, scale: .medium)
    }

    /// Builds one glyph control: a fixed width, the glyph floating in the
    /// middle, the height left to whatever holds it, and a touch region grown
    /// back to a finger's size around the drawn glyph.
    ///
    /// - Parameter width: `controlWidth` for the band's "...";
    ///   `plainControlWidth` for an action on the closing line.
    public static func makeGlyphControl(
        systemName: String, label: String,
        width: CGFloat = controlWidth
    ) -> UIButton {
        let button = PostGlyphButton(type: .system)
        button.configuration = glyphConfiguration(systemName: systemName)
        button.accessibilityLabel = label
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.fixedWidth = width
        return button
    }

    /// The air between the box's edge and the glyph's ink: the glyph is
    /// centred in a control of fixed width, so it is half of what the glyph
    /// leaves of that width. Read off the image the button is drawing, so a
    /// wider glyph (the repost arrows) hangs less than a narrow one (save).
    override var inkLeading: CGFloat {
        guard let button = glyphControl as? PostGlyphButton,
              let configuration = button.configuration,
              let image = configuration.image else { return 0 }
        let drawn = configuration.preferredSymbolConfigurationForImage
            .flatMap { image.applyingSymbolConfiguration($0) } ?? image
        return max((button.fixedWidth - drawn.size.width) / 2, 0)
    }

    override var inkTrailing: CGFloat { inkLeading }

    /// Folds the box's hit-slop onto the control inside it.
    ///
    /// ⚠️ `point(inside:)` alone does NOT give the button a 44pt target. It
    /// lets the touch reach the PILL, and hit-testing then walks its subviews —
    /// which are bounded normally, so a touch beside or below the glyph finds
    /// the content view outside itself, and the pill answers for a press that
    /// was aimed at a control. Clamping the point back into the box — on BOTH
    /// axes now that the box is narrower than a finger too — hands it to the
    /// control it was beside.
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hit = super.hitTest(point, with: event), hit !== self { return hit }
        guard self.point(inside: point, with: event), bounds.height > 2, bounds.width > 2 else {
            return nil
        }
        let clamped = CGPoint(
            x: min(max(point.x, 1), bounds.width - 1),
            y: min(max(point.y, 1), bounds.height - 1)
        )
        let retargeted = super.hitTest(clamped, with: event)
        return retargeted === self ? nil : retargeted
    }
}

/// A glyph control of a card. The pill it sits in is the height of a line of
/// type, which is shorter than a finger — so the drawn glyph stays small and
/// the hit region grows around it, the way `PostMetaPillView` sizes its own
/// chips.
final class PostGlyphButton: UIButton {
    /// The width it was built at (`makeGlyphControl`), kept as a value.
    ///
    /// ⚠️ Not re-read off `constraints`: once laid out a button adds its own
    /// content-size width constraint there, whose constant is the IMAGE's
    /// width — read first, it made the glyph's air zero and the closing line
    /// hung 5pt off its column after the first layout pass.
    var fixedWidth: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let slopY = max((PostMetaPillView.minimumTouchTarget - bounds.height) / 2, 0)
        return bounds.insetBy(dx: 0, dy: -slopY).contains(point)
    }
}
