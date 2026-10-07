import DesignSystem
import UIKit

/// The row closing the notifications list while it has more to load (#608):
/// a spinner while the next page is on its way, or "Try Again" after one
/// failed.
final class NotificationPageFooterCell: UICollectionViewListCell {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        spinner.color = .tertiaryLabel
        spinner.hidesWhenStopped = true
        retryLabel.text = "Try Again"
        retryLabel.font = .appFont(forTextStyle: .subheadline)
        retryLabel.adjustsFontForContentSizeCategory = true
        retryLabel.textColor = .tintColor
        retryLabel.textAlignment = .center
        for view in [spinner, retryLabel] as [UIView] {
            view.constrain(in: contentView) { parent in
                view.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
                view.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            }
        }
        // Tall enough to read as a row, and for a spinner to sit in.
        let height = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
        height.priority = .required - 1
        NSLayoutConstraint.activate([
            height,
            retryLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: Spacing.md),
            retryLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -Spacing.md),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(failed: Bool) {
        retryLabel.isHidden = !failed
        if failed { spinner.stopAnimating() } else { spinner.startAnimating() }
        isAccessibilityElement = true
        accessibilityLabel = failed ? "Try Again" : "Loading more notifications"
        accessibilityTraits = failed ? .button : .staticText
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopAnimating()
    }
}
