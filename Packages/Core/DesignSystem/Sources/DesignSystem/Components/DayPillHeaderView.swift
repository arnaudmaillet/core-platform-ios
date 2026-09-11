import UIKit

/// The floating day chip pinned atop each day of a stream — "Today",
/// "Yesterday", "July 14" — as a collection view's section header.
///
/// The chat transcript's day chip, made shared so the unified conversation and
/// a text post's comments can both carry it (the old conversation screen keeps
/// its own `DayHeaderView` until it is deleted); the words come from
/// `DayTitleFormatter`. Pin it
/// with `NSCollectionLayoutBoundarySupplementaryItem.pinToVisibleBounds` so the
/// current day stays on screen while its rows scroll under it.
///
/// ⚠️ The blur is set on WINDOW ATTACH, never in init: materializing an effect
/// in init contacts the render server and stalls headless CI simulators.
public final class DayPillHeaderView: UICollectionReusableView {
    public static let elementKind = "day-pill-header"

    private let chip = UIVisualEffectView(effect: nil)
    private let label = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)

        label.font = Self.semiboldCaption()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.accessibilityTraits = .header
        label.pin(to: chip.contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.xs, leading: Spacing.md, bottom: Spacing.xs, trailing: Spacing.md
        ))

        chip.clipsToBounds = true
        chip.constrain(in: self) { parent in
            chip.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            chip.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.sm)
            chip.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.xs)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, chip.effect == nil {
            chip.effect = UIBlurEffect(style: .systemThinMaterial)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        chip.layer.cornerRadius = chip.bounds.height / 2
    }

    public func configure(title: String) {
        label.text = title
    }

    /// Caption 1 at semibold, still scaling with Dynamic Type. Local rather
    /// than a public `UIFont` extension: Chat declares its own `withWeight`,
    /// and a public one here would make every call in Chat ambiguous.
    private static func semiboldCaption() -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption1)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
