import DesignSystem
import UIKit

/// One icon+count pair of a metadata line ("♡ 1.2K"). The icon tracks the
/// label's font size through a symbol configuration, so both cell styles
/// (footnote rows, caption2 tile overlays) stay optically matched. Hidden
/// whenever the counter has no value — absence, not an asserted zero.
public final class PostMetricLabel: UIView {
    private let label = UILabel()

    public init(symbol: String, font: UIFont, color: UIColor, shadowed: Bool = false) {
        super.init(frame: .zero)
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font, scale: .small)
        icon.tintColor = color
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = font
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        row.pin(to: self)

        if shadowed {
            // Overlay context (media tiles): legibility over any brightness
            // via a soft shadow, never a scrim — the thumbnail stays clean.
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.55
            layer.shadowRadius = 3
            layer.shadowOffset = .zero
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func set(_ value: Int64?) {
        isHidden = value == nil
        label.text = value.map(PostMetadata.count)
    }
}

extension UIFont {
    /// The tile counters' semibold caption2. Internal to the package: the
    /// cells share one measurement so grid and list stay optically matched.
    static func postGridSystemFont(matching font: UIFont, weight: Weight) -> UIFont {
        UIFont.systemFont(ofSize: font.pointSize, weight: weight)
    }
}
