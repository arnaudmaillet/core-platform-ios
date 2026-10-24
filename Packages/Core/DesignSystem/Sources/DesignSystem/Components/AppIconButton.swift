import UIKit

/// The app's button that is ONE SYMBOL (#1666): a 44pt bubble on a ground —
/// the profile's QR and "...", the place's star, a request's ✕ — or a bare
/// glyph with an optional count — a card's ♡ 1.2K, ☆, ↻, 💬, a row's ✕ — on
/// `AppControl`'s shared behaviour (the press, haptics, hit region, gating,
/// appear / go, menu). Words are `AppButton`'s.
///
/// ```
///   bubble (a 44pt circle on a ground)      glyph (content only)
///      ╭───╮  quiet · prominent              ♡ 1.2K   ☆   ↻
///      │ ⌗ │  tinted · material
///      ╰───╯                                 Button Shapes on → a quiet capsule
/// ```
///
/// Its motions are a symbol's: a symbol swapped for another is replaced
/// (UIKit's replace), a count rolls up or down, a selection cross-fades its
/// tint, a like bounces. Both styles swell under the finger as a system
/// Liquid Glass button does (the owner, 2026-10-24).
@MainActor
open class AppIconButton: AppControl {
    // MARK: - Look

    public enum Style: Equatable, Sendable {
        /// A 44pt circle holding the symbol (`HeroTray.bubbleSize`), on a
        /// ground.
        case bubble(Ground)
        /// The symbol alone, with its count when it has one. A press shows a
        /// dim (or a wash, `washesOnPress`); Button Shapes gives it a quiet
        /// ground.
        case glyph
    }

    /// What the button shows: a symbol, and a count beside it.
    public struct Content: Equatable, Sendable {
        public var symbol: String
        /// Drawn compact (1.2K) in monospaced digits; it is also the
        /// accessibility value.
        public var count: Int?

        public init(symbol: String, count: Int? = nil) {
            self.symbol = symbol
            self.count = count
        }

        public static func symbol(_ symbol: String) -> Content { Content(symbol: symbol) }

        /// The count drawn.
        var text: String? { count.map(CountFormatter.compactString(for:)) }
    }

    // MARK: - State

    public let style: Style
    public private(set) var content: Content

    /// A bubble's ground while selected. Nil swaps prominent and quiet and
    /// keeps the others.
    public var selectedGround: Ground? { didSet { refresh() } }
    /// The SYMBOL's ink while selected (a liked heart's red). The count keeps
    /// the ink: the heart says "yours", the number stays the post's (#934).
    /// Nil keeps the ink.
    public var selectedTint: UIColor? { didSet { refresh() } }
    /// Selected, the symbol is the POINTS HEART (#1128): the heart in the
    /// points gradient (`LikesHeartView`) drawn over the button's own glyph,
    /// which goes clear — the button still lays it out, so nothing moves. At
    /// rest the glyph is the button's own, in its ink. Off by default.
    public var drawsLikesHeart = false { didSet { refresh() } }
    /// The gradient heart, while it is shown.
    public private(set) var likesHeart: LikesHeartView?
    /// A tap also bounces the symbol (a like). Off by default.
    public var bouncesSymbolOnTap = false
    /// Draws the symbol at this point size, medium weight, instead of the
    /// style's text-matched one — a card's actions stand level with its lone
    /// glyphs (`PostActionPillView.glyphPointSize`). Nil: the style's own.
    public var symbolPointSize: CGFloat? { didSet { refresh() } }

    // MARK: - Init

    /// - Parameters:
    ///   - sound: the tick a tap plays (`UISound.tap`). Nil by default.
    ///   - dims: the press also fades the button a little. A glyph defaults
    ///     to it, having no ground to highlight; a bubble does not.
    public init(style: Style, content: Content, sound: UISound? = nil, dims: Bool? = nil) {
        self.style = style
        self.content = content
        super.init(pressStyle: .swell, sound: sound, dims: dims ?? (style == .glyph))
        // A fixed-size symbol does not grow with the text size: a long press
        // shows it large.
        showsLargeContentViewer = true
        scalesLargeContentImage = true
        addInteraction(UILargeContentViewerInteraction())
        refresh()
    }

    // MARK: - Layout

    override open var intrinsicContentSize: CGSize {
        if case .bubble = style {
            return CGSize(width: HeroTray.bubbleSize, height: HeroTray.bubbleSize)
        }
        return super.intrinsicContentSize
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        if let likesHeart, let imageView {
            likesHeart.frame = imageView.convert(imageView.bounds, to: self)
            bringSubviewToFront(likesHeart)
        }
    }

    /// The size the button takes for `content`, resolved now — not at the
    /// next update pass.
    public func fittingSize(for content: Content) -> CGSize {
        if case .bubble = style { return CGSize(width: HeroTray.bubbleSize, height: HeroTray.bubbleSize) }
        let scratch = UIButton(configuration: configuration(for: content))
        scratch.updateConfiguration()
        let fitted = scratch.sizeThatFits(UIView.layoutFittingCompressedSize)
        return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
    }

    // MARK: - Content

    /// Shows `content`. Animated: a count rolls up or down, a symbol is
    /// replaced; the width follows in the same beat.
    public func setContent(_ content: Content, animated: Bool) {
        guard content != self.content else { return }
        let old = self.content
        self.content = content
        guard animated, window != nil else {
            refresh()
            invalidateIntrinsicContentSize()
            superview?.setNeedsLayout()
            return
        }
        let reduced = reducesMotion()
        if old.count != content.count {
            // A symbol changing with it is replaced by the same refresh.
            rollCount(from: old.count ?? 0, to: content.count ?? 0, reduced: reduced)
        } else {
            replaceSymbol(reduced: reduced)
        }
    }

    /// Shows `content` and the selection together — a like is both a filled
    /// heart and a count — in one beat.
    public func setContent(_ content: Content, selected: Bool, animated: Bool) {
        setSelected(selected, animated: animated)
        setContent(content, animated: animated)
    }

    /// The count's own transition: the digits are pushed up when it grows,
    /// down when it shrinks.
    private func rollCount(from old: Int, to new: Int, reduced: Bool) {
        let transition = CATransition()
        transition.duration = Metrics.fadeDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if reduced {
            transition.type = .fade
            record(.countFade)
        } else {
            transition.type = .push
            transition.subtype = new >= old ? .fromTop : .fromBottom
            record(.countRoll(up: new >= old))
        }
        refresh()
        updateConfiguration()
        layoutIfNeeded()
        titleLabel?.layer.add(transition, forKey: "appButton.count")
        resize()
    }

    /// A symbol swapped for another: UIKit's replace transition.
    private func replaceSymbol(reduced: Bool) {
        record(reduced ? .symbolFade : .symbolReplace)
        if reduced {
            UIView.transition(with: self, duration: Metrics.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.refresh()
                self.layoutIfNeeded()
            }
        } else {
            refresh()
        }
        resize()
    }

    /// The width follows the content, the neighbours with it.
    private func resize() {
        guard case .glyph = style else { return }
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        let root = layoutRoot ?? self
        UIView.animate(
            springDuration: Metrics.resizeDuration, bounce: Metrics.resizeBounce,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            root.layoutIfNeeded()
        }
    }

    // MARK: - Selected

    /// Selected (liked, saved, followed): the ground and the symbol's tint
    /// cross-fade.
    public func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != isSelected else { return }
        guard animated, window != nil else {
            isSelected = selected
            return
        }
        record(.stateTint)
        UIView.transition(with: self, duration: Metrics.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.isSelected = selected
            self.updateConfiguration()
            self.layoutIfNeeded()
        }
    }

    // MARK: - Motion

    override open func didTap() {
        if bouncesSymbolOnTap { playSymbolEffect() }
    }

    /// The symbol's own effect on an action (a like): a bounce (a flash of
    /// the ink for a test asking for the fallback).
    public func playSymbolEffect() {
        guard let imageView else { return }
        if reducesMotion() {
            record(.symbolFlash)
            imageView.alpha = 0.35
            UIView.animate(withDuration: Metrics.fadeDuration, delay: 0, options: [.allowUserInteraction]) {
                imageView.alpha = 1
            }
        } else {
            record(.symbolBounce)
            if let likesHeart { likesHeart.bounce() } else { imageView.addSymbolEffect(.bounce) }
        }
    }

    /// An action that came back fine: optionally the symbol changes (a
    /// checkmark), and the success notification plays if asked.
    public func succeed(showing symbol: String? = nil) {
        if notifiesCompletion { notify(.success) }
        guard let symbol else { return }
        setContent(Content(symbol: symbol, count: content.count), animated: true)
    }

    // MARK: - Accessibility

    /// The label a caller gave ("Like"), which a refresh never overwrites.
    private var explicitAccessibilityLabel: String?

    override open var accessibilityLabel: String? {
        get { explicitAccessibilityLabel ?? super.accessibilityLabel }
        set { explicitAccessibilityLabel = newValue }
    }

    override open func refreshAccessibility() {
        super.refreshAccessibility()
        isAccessibilityElement = true
        accessibilityValue = content.count.map(String.init)
        largeContentTitle = content.text ?? accessibilityLabel
        largeContentImage = UIImage.symbol(named: content.symbol)
    }

    // MARK: - Configuration

    /// Whether the gradient heart stands for the glyph now.
    private var showsLikesHeart: Bool {
        drawsLikesHeart && isSelected && isEnabled
    }

    override open func refresh() {
        configuration = configuration(for: content)
        refreshLikesHeart()
        refreshGrounds()
        refreshAccessibility()
    }

    /// The ground drawn now: a bubble's (the selected one when selected); a
    /// glyph's only under Button Shapes.
    override open var currentGround: Ground? {
        switch style {
        case .glyph:
            return buttonShapes() ? .quiet : nil
        case .bubble(let ground):
            guard isSelected else { return ground }
            if let selectedGround { return selectedGround }
            switch ground {
            case .prominent: return .quiet
            case .quiet: return .prominent
            case .tinted, .material: return ground
            }
        }
    }

    /// The configuration for `content`, at the button's style and state.
    func configuration(for content: Content) -> UIButton.Configuration {
        var config: UIButton.Configuration
        switch currentGround {
        case .prominent?:
            config = .filled()
            // The prominent view is the ground; the configuration's fill
            // stays clear over it.
            config.baseBackgroundColor = .clear
            config.baseForegroundColor = .white
        case .quiet?:
            config = .filled()
            config.baseBackgroundColor = HeroTray.fill
            config.baseForegroundColor = .label
        case .tinted?: config = .tinted()
        case .material?:
            config = .plain()
            config.baseForegroundColor = .label
            config.background.backgroundColor = .clear
        case nil:
            config = .plain()
            config.baseForegroundColor = .label
            // ⚠️ `.plain()` GROWS A TINTED GROUND WHEN SELECTED (a liked heart
            // came out on a blue pill). A glyph has no ground in any state;
            // the press is the dim.
            config.background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in .clear }
        }
        if let inkColor { config.baseForegroundColor = inkColor }
        if isSelected, style == .glyph, let selectedTint {
            config.imageColorTransformer = UIConfigurationColorTransformer { _ in selectedTint }
        }
        if showsLikesHeart {
            // The gradient heart draws it (`likesHeart`); the button's own
            // glyph only holds the place.
            config.imageColorTransformer = UIConfigurationColorTransformer { _ in .clear }
        }
        config.cornerStyle = .capsule

        let font = Self.font(for: style)
        config.contentInsets = Self.insets(for: style)
        config.imagePadding = Spacing.xs
        config.preferredSymbolConfigurationForImage = symbolPointSize.map {
            UIImage.SymbolConfiguration(pointSize: $0, weight: .medium, scale: .medium)
        } ?? UIImage.SymbolConfiguration(font: font, scale: style == .glyph ? .small : .medium)
        config.image = UIImage.symbol(named: content.symbol)
        // A symbol swapped for another is replaced — the one symbol motion
        // UIKit does here.
        config.symbolContentTransition = reducesMotion() ? nil : UISymbolContentTransition(.replace)
        if let text = content.text {
            config.attributedTitle = AttributedString(text, attributes: AttributeContainer([.font: font]))
        }

        if !isEnabled {
            // Greyed ground and ink, whatever the style.
            config.baseForegroundColor = .tertiaryLabel
            if currentGround != nil {
                config.background.backgroundColor = .tertiarySystemFill
            }
        }
        return config
    }

    static func font(for style: Style) -> UIFont {
        switch style {
        case .bubble:
            UIFont.scaledSystemFont(ofSize: 17, weight: .regular, relativeTo: .body, maximumPointSize: 22)
        case .glyph:
            UIFont.scaledMonospacedDigitSystemFont(ofSize: 13, weight: .semibold, relativeTo: .footnote, maximumPointSize: 17)
        }
    }

    static func insets(for style: Style) -> NSDirectionalEdgeInsets {
        switch style {
        case .bubble: .zero
        case .glyph: NSDirectionalEdgeInsets(top: Spacing.xs, leading: Spacing.sm, bottom: Spacing.xs, trailing: Spacing.sm)
        }
    }

    /// Mounts or removes the gradient heart for the current state, sized as
    /// the button sizes its glyph.
    private func refreshLikesHeart() {
        guard showsLikesHeart else {
            likesHeart?.removeFromSuperview()
            likesHeart = nil
            return
        }
        let heart = likesHeart ?? {
            let view = LikesHeartView()
            addSubview(view)
            likesHeart = view
            return view
        }()
        heart.configuration = configuration?.preferredSymbolConfigurationForImage ?? AppSymbol.fixed(15)
        heart.setLiked(content.symbol == LikesSymbol.glyph || content.symbol == AppSymbol.liked.rawValue, animated: false)
        heart.ink = configuration?.baseForegroundColor ?? .label
        setNeedsLayout()
    }
}
