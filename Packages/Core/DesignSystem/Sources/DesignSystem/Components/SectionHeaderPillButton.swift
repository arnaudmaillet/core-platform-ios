import UIKit

/// The floating glass capsule every sectioned list wears as its header:
/// leading-aligned, sized by its title, and tapping it scrolls its section back
/// to the top.
///
/// A capsule rather than a full-width frosted band. The band read as structural
/// chrome dividing the list into slabs, where these screens' other floating
/// elements — the search dock, a header's category lens — are all discrete
/// glass objects sitting *over* content. The capsule is the same kind of
/// object, so a screen reads as one system rather than two ideas about what a
/// header is.
///
/// **A real `UIButton` on `UIButton.Configuration.glass()`**, not a
/// `UIVisualEffectView` with a tap recognizer bolted on. That is what buys the
/// native Liquid Glass press behaviour — the deform-and-settle spring, the
/// highlight, the accessibility treatment of a control — none of which a
/// recognizer over an effect view would produce.
///
/// It lives here rather than in any one feature because three different list
/// machineries need the same pill: the compose picker's collection view and the
/// inbox's tables take it inside their reusable header views, and For You's
/// Following grid takes it inside a collection supplementary. All of them host
/// it; none of them owns how it looks.
public final class SectionHeaderPillButton: UIButton {
    public enum Metrics {
        /// Inside the pill. Horizontal is twice the vertical so the text clears
        /// the corner curve instead of crowding into it — at this line height
        /// the radius lands at 18pt, just outside the 16pt inset.
        public static let textInsets = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        )
        /// Around the pill, symmetric: it floats in the band rather than
        /// hanging from either edge of it.
        public static let float = Spacing.sm
    }

    /// Fires when the capsule is tapped. Re-assigned on every configure, since
    /// the hosting view is reused across sections.
    public var onTap: (() -> Void)?

    public init() {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = Metrics.textInsets
        configuration.baseForegroundColor = .secondaryLabel
        self.configuration = configuration
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        // Hugging horizontally so the capsule wraps its title rather than
        // stretching: it is sized by its label, and the space either side of it
        // is the list showing through.
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func setPillTitle(_ title: String?) {
        var attributes = AttributeContainer()
        attributes.font = .preferredFont(forTextStyle: .subheadline).withSemiboldWeight()
        configuration?.attributedTitle = (title?.isEmpty == false)
            ? AttributedString(title!, attributes: attributes)
            : nil
        accessibilityHint = title.map { "Scrolls to the \($0) section" }
    }

    /// Pins the pill into a host header: leading-aligned on the host's margins,
    /// floating clear of the band's top and bottom, and free to be narrower
    /// than the host is wide.
    public func pinAsHeader(in host: UIView) {
        constrain(in: host) { parent in
            leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            topAnchor.constraint(equalTo: parent.topAnchor, constant: Metrics.float)
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Metrics.float)
            trailingAnchor.constraint(lessThanOrEqualTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }
}

private extension UIFont {
    /// Semibold at this font's own size, keeping whatever Dynamic Type has
    /// already scaled it to — a descriptor edit, so the size is never restated.
    func withSemiboldWeight() -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
