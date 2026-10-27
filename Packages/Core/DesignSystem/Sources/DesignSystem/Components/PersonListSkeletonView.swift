import UIKit

/// A list of person-shaped rows before the list has anything to show: an
/// avatar disc, a line of text, a shorter second line, and optionally a
/// short bone at the trailing edge where a time or a count will sit.
///
/// ⚠️ **THIS REPLACES A SPINNER, NOT A BLANK (charter P8).** An activity
/// indicator centred in an empty screen says only that something is
/// happening; rows laid out where the rows will be say WHAT is coming, and
/// the content lands into them without the layout moving. The row height is
/// the person row's own (`PersonListCell`: avatar + `Spacing.sm` above and
/// below), so a skeleton row and the real row it becomes are the same
/// height to the point.
///
/// Enough rows are built to cover the view's height and no more, rebuilt
/// when that height changes. The messages inbox draws its own variant with
/// a preview line; this is the one for every other people list.
public final class PersonListSkeletonView: UIView {
    /// What stands at the row's trailing edge (#1774): the real row's own
    /// furniture, so the skeleton is the row's shape and not another's.
    public enum Trailing: Equatable, Sendable {
        /// Nothing.
        case none
        /// A short bone on the first line, for a time or a count.
        case timeBone
        /// An action pill (Follow, Accept), centred on the row, and — when
        /// `dismiss` is given — a ✕ disc of that diameter after it.
        case action(pillWidth: CGFloat, dismiss: CGFloat?)

        /// Follow and a quiet ✕ — a suggestion row (`SuggestionCell`).
        public static let followAndDismiss = Trailing.action(pillWidth: 78, dismiss: 22)
        /// Accept and a ✕ bubble — a message request (`MessageRequestCell`).
        public static let acceptAndDismiss = Trailing.action(pillWidth: 78, dismiss: 32)
    }

    private let avatarSize: CGFloat
    private let trailing: Trailing
    /// The action pill's height: an `AppButton` at `.row` size.
    static let pillHeight: CGFloat = 30
    private let rows = UIStackView()
    private var builtRowCount = 0

    private static let lineFractions: [CGFloat] = [0.58, 0.42, 0.66, 0.5]
    private static let secondLineFractions: [CGFloat] = [0.34, 0.46, 0.28, 0.4]

    /// - Parameters:
    ///   - avatarSize: the disc the real row draws (48 for a person row, 40
    ///     for an activity row).
    ///   - showsTrailingBone: a short bone at the trailing edge of the first
    ///     line, for rows that carry a time or a count there.
    public convenience init(avatarSize: CGFloat = 48, showsTrailingBone: Bool = false) {
        self.init(avatarSize: avatarSize, trailing: showsTrailingBone ? .timeBone : .none)
    }

    /// - Parameters:
    ///   - avatarSize: the disc the real row draws.
    ///   - trailing: the real row's trailing furniture (#1774).
    public init(avatarSize: CGFloat = 48, trailing: Trailing) {
        self.avatarSize = avatarSize
        self.trailing = trailing
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear

        rows.axis = .vertical
        addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var rowHeight: CGFloat { avatarSize + Spacing.sm * 2 }

    public override func layoutSubviews() {
        super.layoutSubviews()
        rebuildRowsIfNeeded()
    }

    private func rebuildRowsIfNeeded() {
        let height = bounds.height
        guard height > 0 else { return }
        let count = max(1, Int((height / rowHeight).rounded(.up)))
        guard count != builtRowCount else { return }
        builtRowCount = count
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        (0..<count).forEach { rows.addArrangedSubview(makeRow(at: $0)) }
    }

    private func makeRow(at index: Int) -> UIView {
        let avatar = SkeletonBoneView(rounding: .capsule)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: avatarSize)
        ])

        let line = SkeletonBoneView(rounding: .capsule)
        let slack = UIView()
        let timeBone = SkeletonBoneView(rounding: .capsule)
        let firstRow = UIStackView(arrangedSubviews: self.trailing == .timeBone ? [line, slack, timeBone] : [line, slack])
        firstRow.alignment = .center
        firstRow.spacing = Spacing.sm

        let second = SkeletonBoneView(rounding: .capsule)
        let textColumn = UIStackView(arrangedSubviews: [firstRow, second])
        textColumn.axis = .vertical
        textColumn.spacing = 6
        textColumn.alignment = .leading

        var arranged: [UIView] = [avatar, textColumn]
        var actionConstraints: [NSLayoutConstraint] = []
        if case .action(let pillWidth, let dismiss) = self.trailing {
            let pill = SkeletonBoneView(rounding: .capsule)
            arranged.append(pill)
            actionConstraints += [
                pill.widthAnchor.constraint(equalToConstant: pillWidth),
                pill.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            ]
            if let dismiss {
                let disc = SkeletonBoneView(rounding: .capsule)
                arranged.append(disc)
                actionConstraints += [
                    disc.widthAnchor.constraint(equalToConstant: dismiss),
                    disc.heightAnchor.constraint(equalToConstant: dismiss),
                ]
            }
        }
        let row = UIStackView(arrangedSubviews: arranged)
        row.alignment = .center
        row.spacing = Spacing.md
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        )

        NSLayoutConstraint.activate([
            firstRow.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
            line.heightAnchor.constraint(equalToConstant: 13),
            line.widthAnchor.constraint(
                equalTo: textColumn.widthAnchor,
                multiplier: Self.lineFractions[index % Self.lineFractions.count]
            ),
            second.heightAnchor.constraint(equalToConstant: 11),
            second.widthAnchor.constraint(
                equalTo: textColumn.widthAnchor,
                multiplier: Self.secondLineFractions[index % Self.secondLineFractions.count]
            ),
            timeBone.heightAnchor.constraint(equalToConstant: 11),
            timeBone.widthAnchor.constraint(equalToConstant: 34),
            row.heightAnchor.constraint(equalToConstant: rowHeight)
        ] + actionConstraints)
        return row
    }

    #if DEBUG
    /// The bones of the first row — what a test reads.
    var debugFirstRowBoneCount: Int {
        layoutIfNeeded()
        func bones(in view: UIView) -> Int {
            view.subviews.reduce(0) { $0 + ($1 is SkeletonBoneView && !$1.isHidden ? 1 : bones(in: $1)) }
        }
        return rows.arrangedSubviews.first.map(bones(in:)) ?? 0
    }
    #endif
}
