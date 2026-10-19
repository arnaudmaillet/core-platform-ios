import UIKit

/// THE POINTS HEART (#1128, #1124 decision 7): the app's own heart glyph
/// (`AppSymbol.like` / `.liked`) drawn in the yellow → orange → pink
/// gradient (`Palette.likesGradient`) once liked, and in the row's ink at
/// rest.
///
/// ⚠️ A three-stop gradient is not something SF Symbols draw: their gradient
/// rendering derives from ONE colour. So the heart is a MASK — the symbol in
/// an image view — over a gradient layer. The image view stays a symbol image
/// view, so the like's bounce and the outline → filled replace still play
/// (`bounce()`, `setLiked(_:animated:)`), on the mask itself.
///
/// ```
///   LikesHeartView
///   └─ fill (UIView, its layer a CAGradientLayer — the colour)
///        mask: glyph (UIImageView, the heart symbol — the shape)
/// ```
public final class LikesHeartView: UIView {
    /// The heart's shape: what the mask draws, and what animates.
    public let glyph = UIImageView()
    private let fill = GradientFill()

    /// Liked: the gradient, filled heart. At rest: the outline, in `ink`.
    public private(set) var isLiked = false
    /// The heart's colour at rest — the content's ink.
    public var ink: UIColor = .secondaryLabel {
        didSet { applyColours() }
    }
    /// The symbol's size and weight (`AppSymbol.fixed` / `.textStyle`).
    public var configuration: UIImage.SymbolConfiguration {
        didSet { applyGlyph(animated: false) }
    }

    public init(configuration: UIImage.SymbolConfiguration = AppSymbol.fixed(15, weight: .semibold)) {
        self.configuration = configuration
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        addSubview(fill)
        glyph.contentMode = .center
        fill.mask = glyph
        applyGlyph(animated: false)
        applyColours()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: LikesHeartView, _: UITraitCollection) in
            view.applyColours()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Liked or not; animated, the outline is REPLACED by the filled heart
    /// (the symbol's own content transition) and the colour crossfades.
    public func setLiked(_ liked: Bool, animated: Bool) {
        guard liked != isLiked else { return }
        isLiked = liked
        applyGlyph(animated: animated)
        if animated {
            UIView.transition(with: fill, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.applyColours()
            }
        } else {
            applyColours()
        }
    }

    /// The like's bounce, played by the shape.
    public func bounce() {
        glyph.addSymbolEffect(.bounce)
    }

    /// The colours `fill` draws now, resolved — what a test reads.
    var drawnColours: [UIColor] { fill.colours }

    public override var intrinsicContentSize: CGSize {
        glyph.image?.size ?? CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = bounds
        glyph.frame = fill.bounds
    }

    private func applyGlyph(animated: Bool) {
        // ⚠️ A FIXED INK: a mask view is outside the hierarchy, and a template
        // image there has no tint to draw with — the mask came out empty and
        // the heart drew nothing. Black is opaque; only its alpha masks.
        let image = (isLiked ? AppSymbol.liked : AppSymbol.like).image(configuration)?
            .withTintColor(.black, renderingMode: .alwaysOriginal)
        if animated, let image {
            glyph.setSymbolImage(image, contentTransition: .replace)
        } else {
            glyph.image = image
        }
        invalidateIntrinsicContentSize()
    }

    private func applyColours() {
        if isLiked {
            fill.colours = Palette.likesGradient(for: traitCollection)
        } else {
            let resolved = ink.resolvedColor(with: traitCollection)
            fill.colours = [resolved, resolved]
        }
    }
}

/// A view whose layer is the gradient: it lays out with the view, no frame
/// bookkeeping, and implicit layer animations stay off.
private final class GradientFill: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    var colours: [UIColor] = [] {
        didSet { gradient.colors = colours.map(\.cgColor) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Bottom-left to top-right, as the brand gradient runs (#1124).
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The gradient heart laid over a plain `UIButton`'s glyph (#1128) — for a
/// button that is not an `AppButton` (which has `drawsLikesHeart`): the
/// Snap like pill, the comment composer's. The button keeps laying out its
/// glyph, drawn clear (`clearGlyph`), and the heart sits exactly on it.
///
/// The host calls `update(on:liked:)` when the state changes and
/// `layout(on:)` from a layout pass.
@MainActor
public final class LikesHeartOverlay {
    public private(set) var heart: LikesHeartView?

    public init() {}

    /// The filled heart as the button lays it out but does not draw: the
    /// gradient heart draws it.
    public static func clearGlyph(_ configuration: UIImage.SymbolConfiguration) -> UIImage? {
        LikesSymbol.glyphImage(configuration)?.withTintColor(.clear, renderingMode: .alwaysOriginal)
    }

    /// Shows the gradient heart over `button`'s glyph while `liked`.
    public func update(on button: UIButton, liked: Bool, configuration: UIImage.SymbolConfiguration) {
        guard liked else {
            heart?.removeFromSuperview()
            heart = nil
            return
        }
        let view = heart ?? {
            let view = LikesHeartView(configuration: configuration)
            button.addSubview(view)
            heart = view
            return view
        }()
        view.configuration = configuration
        view.setLiked(true, animated: false)
        button.setNeedsLayout()
    }

    /// Places the heart on the glyph — call after the button's layout.
    public func layout(on button: UIButton) {
        guard let heart, let imageView = button.imageView else { return }
        heart.frame = imageView.convert(imageView.bounds, to: button)
        button.bringSubviewToFront(heart)
    }

    /// The like's bounce, on the heart when it is shown.
    public func bounce() {
        heart?.bounce()
    }
}
