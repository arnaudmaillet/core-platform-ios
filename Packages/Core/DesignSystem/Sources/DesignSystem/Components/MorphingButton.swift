import UIKit

/// A system button whose state changes are a little transition rather than a
/// cut (#726): Follow → Following → Requested and back.
///
/// - **The content goes through a blur.** A material veil blurs the old
///   title in, the new configuration lands under it, and the veil clears on
///   the new one.
/// - **The capsule resizes on a spring**, the new title's width reached
///   with a small overshoot — the superview's layout runs inside the same
///   spring, so a button pinned to one edge grows from the other.
/// - **It keeps a native button's feel**: a press scales it down, a long
///   press further, and the release bounces it back.
///
/// It IS a `UIButton` with a `UIButton.Configuration`: everything else —
/// styles, highlight tinting, accessibility, actions — is UIKit's.
open class MorphingButton: UIButton {
    /// How long a whole morph takes: blur in, swap, blur out.
    public static let morphDuration: TimeInterval = 0.36
    /// How far a press, and a long press, scale the button down.
    public static let pressScale: CGFloat = 0.94
    public static let longPressScale: CGFloat = 0.88
    /// How long a press must be held to count as a long press.
    public static let longPressDelay: TimeInterval = 0.45

    /// The veil the content blurs under while it changes.
    private let veil = UIVisualEffectView(effect: nil)
    private var longPressTimer: Timer?
    /// Whether a state change is on screen now. Public for tests.
    public private(set) var isMorphing = false
    /// Whether the press is being held long. Public for tests.
    public private(set) var isLongPressed = false

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    public convenience init(configuration: UIButton.Configuration) {
        self.init(frame: .zero)
        self.configuration = configuration
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUp() {
        veil.isUserInteractionEnabled = false
        veil.cornerConfiguration = .capsule()
        veil.clipsToBounds = true
        veil.isHidden = true
        addSubview(veil)
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        veil.frame = bounds
        bringSubviewToFront(veil)
    }

    /// Moves to `configuration`: through the blur and a spring resize when
    /// `animated` and on screen, at once otherwise.
    public func morph(to configuration: UIButton.Configuration, animated: Bool) {
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            apply(configuration)
            return
        }
        isMorphing = true
        veil.isHidden = false
        veil.layer.removeAllAnimations()
        let half = Self.morphDuration / 2
        UIView.animate(withDuration: half, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
            self.veil.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        } completion: { _ in
            self.apply(configuration)
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.62,
                           initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]) {
                (self.superview ?? self).layoutIfNeeded()
            }
            UIView.animate(withDuration: half, delay: 0.04, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.veil.effect = nil
            } completion: { _ in
                self.veil.isHidden = true
                self.isMorphing = false
            }
        }
    }

    /// Sets the configuration and makes its size count now: a
    /// `UIButton.Configuration` resolves at the button's next update pass,
    /// so without the forced pass the intrinsic size still says the old
    /// title's.
    private func apply(_ configuration: UIButton.Configuration) {
        self.configuration = configuration
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
    }

    // MARK: - Press

    override open var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted {
                pressDown()
            } else {
                release()
            }
        }
    }

    private func pressDown() {
        longPressTimer?.invalidate()
        animateScale(to: Self.pressScale, damping: 0.8)
        longPressTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isHighlighted else { return }
                self.isLongPressed = true
                self.animateScale(to: Self.longPressScale, damping: 0.8)
            }
        }
    }

    private func release() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        isLongPressed = false
        // Back past its size and home: the bounce.
        animateScale(to: 1, damping: 0.45)
    }

    private func animateScale(to scale: CGFloat, damping: CGFloat) {
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: damping,
                       initialSpringVelocity: 0.6, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    /// The veil's blur, nil when clear. Public for tests.
    public var veilEffect: UIVisualEffect? { veil.isHidden ? nil : veil.effect }
}
