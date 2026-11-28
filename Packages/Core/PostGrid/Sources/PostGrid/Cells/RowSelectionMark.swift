import DesignSystem
import UIKit

/// The select mode's circle — the one a History row (`PostHistoryRowCell`,
/// the owner 2026-11-08) and a list card (`PostGridListRowCell`, Saved, the
/// owner 2026-11-28) wear: empty in `.tertiaryLabel`, or the brand's check,
/// swapped by the symbol's own Replace. Where it stands, and how it comes
/// and goes, are its row's.
public final class RowSelectionMark: UIImageView {
    /// The circle's side.
    public static let side: CGFloat = 24

    /// Whether it wears the check.
    public private(set) var isChecked = false

    public init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        contentMode = .center
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        drawCheck(animated: false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Checks or empties the circle; `animated` swaps it by Replace, unless
    /// the viewer reduces motion.
    public func setChecked(_ checked: Bool, animated: Bool) {
        guard checked != isChecked else { return }
        isChecked = checked
        drawCheck(animated: animated)
    }

    private func drawCheck(animated: Bool) {
        let image = UIImage(systemName: isChecked ? "checkmark.circle.fill" : "circle")
        tintColor = isChecked ? Palette.tint : .tertiaryLabel
        if animated, !MotionPreference.reducesMotion, let image {
            setSymbolImage(image, contentTransition: .replace)
        } else {
            self.image = image
        }
    }
}
