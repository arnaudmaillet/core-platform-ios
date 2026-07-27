import DesignSystem
import UIKit

/// One action in the share sheet's tray, in the system share sheet's own
/// shape: a filled circle carrying the glyph, with a plain caption beneath it.
///
/// The circle is around the ICON only, not around icon-and-label together —
/// that is what makes the row read as the system's, and it is why this isn't
/// simply a `UIButton.Configuration` with `imagePlacement = .top` (which would
/// wrap both in one capsule and drift wider with every label).
///
/// ⚠️ **Opaque, not glass — because the SHEET is glass.** These were built on
/// `.glass()` first and the non-prominent one came out invisible in-sim: a
/// glass button on a glass surface has nothing distinct to refract and simply
/// dissolves into it. Same double-material trap `GlassSegmentRow` documents
/// for bar items, arriving from the other direction. The system's own share
/// sheet does exactly this too — its activity circles are opaque tiles on the
/// sheet's material, never glass-on-glass.
///
/// The visible column is inert and a button sits over the whole thing, so the
/// caption is as tappable as the circle — a 56pt target with a label under it
/// that does nothing is a small trap.
final class ProfileShareActionChip: UIView {
    private enum Metrics {
        static let diameter: CGFloat = 58
        /// Caption width cap. Wide enough for two short words, narrow enough
        /// that the tray's rhythm survives a long label.
        static let width: CGFloat = 76
    }

    init(title: String, symbol: String, prominent: Bool, action: @escaping () -> Void) {
        super.init(frame: .zero)

        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        )
        configuration.contentInsets = .zero
        configuration.cornerStyle = .capsule
        // `.withAlphaComponent(1)` on the neutral fill for the reason the whole
        // sheet documents: semantic colours resolve TRANSLUCENT inside an iOS
        // 26 sheet, and a translucent circle over glass is no circle at all.
        configuration.baseBackgroundColor = prominent
            ? .tintColor
            : UIColor.secondarySystemBackground.withAlphaComponent(1)
        configuration.baseForegroundColor = prominent ? .white : .label
        let icon = UIButton(configuration: configuration)
        icon.isUserInteractionEnabled = false

        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        // Two lines so a longer verb wraps instead of truncating to nonsense;
        // the tray's items stay top-aligned so one wrapped label can't shove
        // its neighbours' circles down.
        label.numberOfLines = 2

        let column = UIStackView(arrangedSubviews: [icon, label])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Spacing.sm
        column.isUserInteractionEnabled = false

        let button = UIButton(type: .system)
        button.accessibilityLabel = title
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        // A press dips the whole chip, glyph and caption together.
        button.configurationUpdateHandler = { [weak column] button in
            column?.alpha = button.isHighlighted ? 0.55 : 1
        }
        column.pin(to: button)
        button.pin(to: self)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Metrics.diameter),
            icon.heightAnchor.constraint(equalToConstant: Metrics.diameter),
            widthAnchor.constraint(equalToConstant: Metrics.width)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
