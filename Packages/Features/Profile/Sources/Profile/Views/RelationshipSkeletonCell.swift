import DesignSystem
import UIKit

/// One loading row in a relationship list: identity disc, a name bone, a
/// shorter handle bone, and a capsule where the action button will land.
///
/// A *cell*, not an overlay. The list's first page is a real page — it arrives
/// all at once and replaces these — but the boundary between "rows" and "still
/// loading" has to be placed by the layout, which already knows where the last
/// row ended; computing it by hand against a diffable apply (whose content size
/// isn't final when the apply returns) lands the bones on top of the rows they
/// were meant to follow. The compose picker learned this the hard way; this is
/// the same shape with the trailing button's silhouette added.
final class RelationshipSkeletonCell: UICollectionViewListCell {
    private enum Metrics {
        /// `MonogramAvatarView.rowDiameter` (copied, not referenced: this
        /// nonisolated constant can't read a main-actor one).
        static let avatarSize: CGFloat = 48
        static let nameHeight: CGFloat = 13
        static let handleHeight: CGFloat = 11
        static let actionWidth: CGFloat = 82
        static let actionHeight: CGFloat = 28
        /// Bone widths cycle these so a screenful reads as a list of different
        /// people rather than one row stamped repeatedly.
        static let nameFractions: [CGFloat] = [0.46, 0.34, 0.54, 0.40]
        static let handleFractions: [CGFloat] = [0.30, 0.40, 0.26, 0.34]
        /// What one row occupies, used to work out how many reach the bottom.
        static let rowHeight: CGFloat = avatarSize + Spacing.sm * 2
    }

    /// How many rows of this height it takes to fill `height`, rounded up so
    /// the last one runs past the bottom edge instead of leaving a gap.
    static func rowsToFill(_ height: CGFloat) -> Int {
        guard height > 0 else { return 0 }
        return max(1, Int((height / Metrics.rowHeight).rounded(.up)))
    }

    private let avatar = SkeletonBoneView(rounding: .capsule)
    private let name = SkeletonBoneView(rounding: .capsule)
    private let handle = SkeletonBoneView(rounding: .capsule)
    private let action = SkeletonBoneView(rounding: .capsule)
    private var nameWidth: NSLayoutConstraint!
    private var handleWidth: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        let textColumn = UIStackView(arrangedSubviews: [name, handle])
        textColumn.axis = .vertical
        textColumn.spacing = 6
        textColumn.alignment = .leading

        let row = UIStackView(arrangedSubviews: [avatar, textColumn, action])
        row.alignment = .center
        row.spacing = Spacing.md
        row.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        ))

        nameWidth = name.widthAnchor.constraint(
            equalTo: textColumn.widthAnchor, multiplier: Metrics.nameFractions[0]
        )
        handleWidth = handle.widthAnchor.constraint(
            equalTo: textColumn.widthAnchor, multiplier: Metrics.handleFractions[0]
        )
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Metrics.avatarSize),
            action.widthAnchor.constraint(equalToConstant: Metrics.actionWidth),
            action.heightAnchor.constraint(equalToConstant: Metrics.actionHeight),
            name.heightAnchor.constraint(equalToConstant: Metrics.nameHeight),
            handle.heightAnchor.constraint(equalToConstant: Metrics.handleHeight),
            nameWidth,
            handleWidth
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `index` continues the width cycle across the whole run of rows, so the
    /// pattern doesn't restart partway down the screen.
    func configure(at index: Int) {
        // Multipliers are immutable, so varying a width means replacing its
        // constraint rather than assigning to it.
        NSLayoutConstraint.deactivate([nameWidth, handleWidth])
        guard let textColumn = name.superview else { return }
        nameWidth = name.widthAnchor.constraint(
            equalTo: textColumn.widthAnchor,
            multiplier: Metrics.nameFractions[index % Metrics.nameFractions.count]
        )
        handleWidth = handle.widthAnchor.constraint(
            equalTo: textColumn.widthAnchor,
            multiplier: Metrics.handleFractions[index % Metrics.handleFractions.count]
        )
        NSLayoutConstraint.activate([nameWidth, handleWidth])
    }
}

/// The footer row under the last loaded page: a spinner that says the list is
/// continuing, not that it has ended.
final class RelationshipPagingCell: UICollectionViewListCell {
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        spinner.color = .tertiaryLabel
        spinner.constrain(in: contentView) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.lg)
            spinner.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.lg)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func startAnimating() {
        spinner.startAnimating()
    }
}
