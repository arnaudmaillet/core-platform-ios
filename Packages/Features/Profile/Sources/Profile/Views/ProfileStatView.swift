import DesignSystem
import UIKit

/// A single counter column: a bold value over a muted caption
/// ("1.2K" / "Followers"). Vertically stacked, center-aligned.
final class ProfileStatView: UIView {
    private let valueLabel = UILabel()
    private let captionLabel = UILabel()

    init(caption: String) {
        super.init(frame: .zero)

        valueLabel.font = .preferredFont(forTextStyle: .headline)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = .label
        valueLabel.textAlignment = .center

        captionLabel.text = caption
        // caption1, not footnote: four of these share the identity column
        // beside the avatar (~64pt per cell on a 393pt screen), and
        // "Followers" must fit that cell without truncating.
        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .secondaryLabel
        captionLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [valueLabel, captionLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.xs
        stack.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setValue(_ text: String) {
        valueLabel.text = text
    }

    // MARK: - Redaction

    private var bone: SkeletonBoneView?

    /// Skeleton state for the (data-driven) value only — the caption is
    /// chrome and stays. A blank placeholder value holds the headline line's
    /// height so the row cannot shift when the real count lands; the bone
    /// rides the value label's own center. Alpha-only, so a reveal inside an
    /// animation block cross-fades.
    func setRedacted(_ redacted: Bool) {
        if redacted, bone == nil {
            let bone = SkeletonBoneView()
            bone.constrain(in: self) { _ in
                bone.centerXAnchor.constraint(equalTo: valueLabel.centerXAnchor)
                bone.centerYAnchor.constraint(equalTo: valueLabel.centerYAnchor)
                bone.widthAnchor.constraint(equalToConstant: 40)
                bone.heightAnchor.constraint(equalToConstant: 14)
            }
            self.bone = bone
        }
        if redacted {
            valueLabel.text = " "
            valueLabel.alpha = 0
            bone?.isHidden = false
            bone?.alpha = 1
        } else {
            valueLabel.alpha = 1
            bone?.alpha = 0
        }
    }
}
