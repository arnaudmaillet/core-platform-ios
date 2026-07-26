import DesignSystem
import UIKit

/// The row at the end of the suggestions list while the next page is on its way.
///
/// Deliberately small and quiet. This spinner appears *under a full list* — the
/// viewer already has plenty to look at and has not asked for anything, they
/// simply scrolled. Anything larger reads as the screen reloading rather than
/// as the list continuing. (The first load is the opposite situation and gets
/// the opposite treatment: `PersonSkeletonCell` fills the empty screen.)
final class PagingSpinnerCell: UICollectionViewListCell {
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        spinner.hidesWhenStopped = false
        spinner.color = .tertiaryLabel
        spinner.constrain(in: contentView) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.md)
            spinner.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.md)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func startAnimating() {
        spinner.startAnimating()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopAnimating()
    }
}
