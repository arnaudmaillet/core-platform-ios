import DesignSystem
import UIKit

/// The floating day chip pinned atop each transcript day section ("Today",
/// "July 14"). Material-backed so it stays legible over bubbles while pinned.
final class DayHeaderView: UICollectionReusableView {
    static let elementKind = "chat-day-header"

    // Effect set on window attach: materializing one in init contacts the
    // render server and stalls headless CI simulators (see ci memory).
    private let chip = UIVisualEffectView(effect: nil)
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        label.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
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
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, chip.effect == nil {
            chip.effect = UIBlurEffect(style: .systemThinMaterial)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        chip.layer.cornerRadius = chip.bounds.height / 2
    }

    func configure(title: String) {
        label.text = title
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
