import DesignSystem
import UIKit

/// A section title in the compose picker: a floating glass capsule, pinned over
/// the rows scrolling beneath it, that taps to scroll its section back to the
/// top.
///
/// A capsule rather than a full-width frosted band: the band read as structural
/// chrome dividing the list into slabs, where this screen's other floating
/// elements — the search dock, the inbox's category lens — are all discrete
/// glass objects sitting *over* content. The capsule is the same kind of
/// object, so the screen reads as one system rather than two ideas about what a
/// header is. `DayHeaderView` does exactly this for the transcript's day
/// markers; this is its leading-aligned, tappable sibling.
///
/// Nothing sits behind the capsule — no band, no scrim, no gradient. The glass
/// pill is the entire header, and the list shows through everywhere around it.
///
/// The pill is a real `UIButton` on `UIButton.Configuration.glass()` rather
/// than a `UIVisualEffectView` with a tap recognizer bolted on. That is what
/// buys the native Liquid Glass press behaviour — the deform-and-settle spring,
/// the highlight, and the accessibility treatment of a control — none of which
/// a recognizer over an effect view would produce.
final class SectionHeaderCapsuleView: UICollectionReusableView {
    private enum Metrics {
        /// Inside the pill. Horizontal is twice the vertical so the text clears
        /// the corner curve instead of crowding into it — at this line height
        /// the radius lands at 18pt, just outside the 16pt inset.
        static let textInsets = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        )
        /// Around the pill, symmetric: it floats in the band rather than
        /// hanging from either edge of it.
        static let float = Spacing.sm
    }

    /// Fires when the capsule is tapped. Re-assigned on every configure, since
    /// the view is reused across sections.
    var onTap: (() -> Void)?

    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)

        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = Metrics.textInsets
        configuration.baseForegroundColor = .secondaryLabel
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)

        // Hugging horizontally so the capsule wraps the title rather than
        // stretching: it is sized by its label, and the space either side of it
        // is the list showing through.
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.constrain(in: self) { parent in
            button.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            button.topAnchor.constraint(equalTo: parent.topAnchor, constant: Metrics.float)
            button.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Metrics.float)
            button.trailingAnchor.constraint(
                lessThanOrEqualTo: parent.layoutMarginsGuide.trailingAnchor
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    func setTitle(_ title: String?) {
        var attributes = AttributeContainer()
        attributes.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        button.configuration?.attributedTitle = (title?.isEmpty == false)
            ? AttributedString(title!, attributes: attributes)
            : nil
        button.accessibilityHint = title.map { "Scrolls to the \($0) section" }
    }
}
