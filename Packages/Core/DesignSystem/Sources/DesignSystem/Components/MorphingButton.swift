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
/// - **Its press is the app's one press** (`PressFeedback`): it gives ONCE
///   under the finger, holds there however long the finger stays, and springs
///   back once on release — the same press as every button beside it.
///
/// ⚠️ **ONE PRESS, AND IT IS `PressFeedback`, ATTACHED HERE** (#866). The
/// button used to scale ITSELF from `isHighlighted` — 0.94 on touch-down, then
/// a timer took it on to 0.88 after 0.45 s held — so a long press shrank in
/// two steps, and the profile header, which also attaches `PressFeedback` to
/// its tray, stacked a second scale on top of the first. A host must NOT
/// attach another press to a `MorphingButton`: it already has one.
///
/// It IS a `UIButton` with a `UIButton.Configuration`: everything else —
/// styles, highlight tinting, accessibility, actions — is UIKit's.
///
/// Only the profile header's Follow wears it now: the person rows (relation
/// lists, the inbox's Requests and Suggestions) moved to `AppButton` (#932),
/// and the header follows with #933.
open class MorphingButton: UIButton {
    /// How long a whole morph takes: blur in, swap, blur out.
    public static let morphDuration: TimeInterval = 0.36

    /// The veil the content blurs under while it changes.
    private let veil = UIVisualEffectView(effect: nil)
    /// Whether a state change is on screen now. Public for tests.
    public private(set) var isMorphing = false

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
        // Silent: the action answers (a Follow morphs). The configuration's
        // own highlight is the dim, so only the shrink is added.
        PressFeedback.attach(to: self, sound: nil)
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

    /// The veil's blur, nil when clear. Public for tests.
    public var veilEffect: UIVisualEffect? { veil.isHidden ? nil : veil.effect }
}
