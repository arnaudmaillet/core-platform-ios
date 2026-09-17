import UIKit

/// The bin an overlay is dropped in to delete it. It shows only while an
/// overlay is being dragged, at the foot of the part of the page the chrome
/// leaves clear.
///
/// ⚠️ **THE FINGER DECIDES, NOT THE OVERLAY.** An overlay's centre is held
/// inside the visible picture (`MediaOverlayGeometry.moved`), and on a fitted
/// picture the bin can sit below it — so the drop is judged on where the finger
/// is, which can reach the bin whatever the picture's shape.
@MainActor
final class MediaOverlayTrashView: UIView {
    static let side: CGFloat = 56
    /// How far around the bin a finger still counts as over it.
    static let reach: CGFloat = 16

    private let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let icon = UIImageView(image: UIImage(systemName: "trash"))
    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    /// Whether a finger holding an overlay is over the bin.
    private(set) var isArmed = false

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isUserInteractionEnabled = false
        isHidden = true
        alpha = 0
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.layer.cornerRadius = Self.side / 2
        glass.clipsToBounds = true
        addSubview(glass)
        icon.tintColor = .white
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        icon.frame = bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(icon)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows or hides the bin, disarmed either way.
    func setShowing(_ isShowing: Bool) {
        setArmed(false)
        if isShowing {
            feedback.prepare()
            isHidden = false
        }
        let reduce = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduce ? 0 : 0.18, delay: 0, options: [.beginFromCurrentState]) {
            self.alpha = isShowing ? 1 : 0
        } completion: { _ in
            if self.alpha == 0 { self.isHidden = true }
        }
    }

    /// Whether `point`, in the bin's superview, is over the bin.
    func covers(_ point: CGPoint) -> Bool {
        !isHidden && frame.insetBy(dx: -Self.reach, dy: -Self.reach).contains(point)
    }

    /// Lights the bin while a finger is over it, with a tap of the engine the
    /// moment it is reached.
    func setArmed(_ armed: Bool) {
        guard armed != isArmed else { return }
        isArmed = armed
        if armed { feedback.impactOccurred() }
        glass.backgroundColor = armed ? UIColor.systemRed.withAlphaComponent(0.8) : .clear
        let scale: CGFloat = armed && !UIAccessibility.isReduceMotionEnabled ? 1.2 : 1
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
            self.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }
}
