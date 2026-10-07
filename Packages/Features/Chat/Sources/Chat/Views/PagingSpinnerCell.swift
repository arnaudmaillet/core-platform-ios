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

/// How close to the end of an inbox list a row has to be for its coming on
/// screen to ask for the next page (#593).
enum InboxPaging {
    static let nearEndRowCount = 5
}

/// The same quiet spinner as a table's footer: the inbox lists are tables, and
/// it sits under their last row while another page is there to load (#593).
///
/// It turns only while the end of the list is in reach — the owner starts it
/// when a row near the end comes on screen and stops it when the list changes
/// under it. An endless spinner under rows the viewer is not looking at still
/// redraws the screen every frame (#580).
final class PagingSpinnerFooterView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 56))
        isUserInteractionEnabled = false
        spinner.hidesWhenStopped = false
        spinner.color = .tertiaryLabel
        spinner.constrain(in: self) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSpinning(_ spinning: Bool) {
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}
