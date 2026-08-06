import UIKit

/// One loading row: an identity disc, a name bone and a shorter handle bone —
/// `PersonListCell`'s silhouette with the text taken out.
///
/// A *cell*, not an overlay view. A person list's loading state is rarely
/// all-or-nothing — in the compose picker recents are free and land
/// immediately while the social-graph fan-out is still running — so the
/// shimmer has to begin exactly where the loaded rows stop. Hanging a skeleton
/// view over the list meant computing that boundary by hand — and getting it
/// wrong, because a diffable apply's content
/// size isn't final when the apply returns, so the bones landed *on top of* the
/// rows they were supposed to follow. As collection view items they are placed
/// by the layout, which already knows where the last row ended.
public final class PersonSkeletonCell: UICollectionViewListCell {
    private enum Metrics {
        /// `MonogramAvatarView.rowDiameter` (copied, not referenced: this
        /// nonisolated constant can't read a main-actor one).
        static let avatarSize: CGFloat = 48
        static let nameHeight: CGFloat = 13
        static let handleHeight: CGFloat = 11
        /// Bone widths cycle these so a screenful reads as a list of different
        /// people rather than one row stamped repeatedly.
        static let nameFractions: [CGFloat] = [0.44, 0.34, 0.52, 0.38]
        static let handleFractions: [CGFloat] = [0.30, 0.38, 0.26, 0.34]
        /// What one row occupies, used to work out how many it takes to reach
        /// the bottom of the screen.
        static let rowHeight: CGFloat = avatarSize + Spacing.sm * 2
    }

    /// How many rows of this height it takes to fill `height`, rounded up so
    /// the last one runs past the bottom edge instead of leaving a gap.
    public static func rowsToFill(_ height: CGFloat) -> Int {
        guard height > 0 else { return 0 }
        return max(1, Int((height / Metrics.rowHeight).rounded(.up)))
    }

    private let avatar = SkeletonBoneView(rounding: .capsule)
    private let name = SkeletonBoneView(rounding: .capsule)
    private let handle = SkeletonBoneView(rounding: .capsule)
    private var nameWidth: NSLayoutConstraint!
    private var handleWidth: NSLayoutConstraint!

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        let textColumn = UIStackView(arrangedSubviews: [name, handle])
        textColumn.axis = .vertical
        textColumn.spacing = 6
        textColumn.alignment = .leading

        let row = UIStackView(arrangedSubviews: [avatar, textColumn])
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
            name.heightAnchor.constraint(equalToConstant: Metrics.nameHeight),
            handle.heightAnchor.constraint(equalToConstant: Metrics.handleHeight),
            nameWidth,
            handleWidth
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `index` continues the width cycle across the whole run of rows, so the
    /// pattern doesn't restart when the skeleton shrinks as content lands.
    public func configure(at index: Int) {
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
