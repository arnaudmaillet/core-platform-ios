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
        captionLabel.font = .preferredFont(forTextStyle: .footnote)
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
}
