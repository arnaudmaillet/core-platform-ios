import UIKit

/// The floating day chip pinned atop each day of a stream — "Today",
/// "Yesterday", "July 14" — as a collection view's section header.
///
/// The chat transcript's day chip, shared so a conversation and a text post's
/// comments can both carry it; the words come from `DayTitleFormatter`. Pin it
/// with `NSCollectionLayoutBoundarySupplementaryItem.pinToVisibleBounds` so the
/// current day stays on screen while its rows scroll under it.
///
/// ⚠️ The blur is set on WINDOW ATTACH, never in init: materializing an effect
/// in init contacts the render server and stalls headless CI simulators.
public final class DayPillHeaderView: UICollectionReusableView {
    public static let elementKind = "day-pill-header"

    private let chip = UIVisualEffectView(effect: nil)
    private let label = UILabel()
    private var chipBottom: NSLayoutConstraint!

    /// The space above the chip, from the band's top.
    public static let topGap: CGFloat = Spacing.sm
    /// The space under the chip, down to its day's first row (#2238): at
    /// least the space above it and close to the gap between two messages.
    /// It was `Spacing.xs` (4 pt) and the chip read as glued to the message
    /// under it and far from the one above (the owner, 2026-11-10).
    public static let bottomGap: CGFloat = Spacing.md

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
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)
        chipBottom = chip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomGap)
        NSLayoutConstraint.activate([
            chip.centerXAnchor.constraint(equalTo: centerXAnchor),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: Self.topGap),
            chipBottom,
        ])
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

    /// The space under the chip, for a host whose rows sit differently
    /// (#2238); `bottomGap` unless set.
    public var gapBelow: CGFloat {
        get { -chipBottom.constant }
        set { chipBottom.constant = -newValue }
    }

    #if DEBUG
    /// The chip's frame in the header, for tests.
    public var debugChipFrame: CGRect { chip.frame }
    #endif

    /// Caption 1 at semibold, still scaling with Dynamic Type. Local rather
    /// than a public `UIFont` extension: Chat declares its own `withWeight`,
    /// and a public one here would make every call in Chat ambiguous.
    private static func semiboldCaption() -> UIFont {
        let base = UIFont.appFont(forTextStyle: .caption1)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
