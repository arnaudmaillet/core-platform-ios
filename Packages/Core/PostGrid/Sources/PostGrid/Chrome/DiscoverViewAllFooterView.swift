import DesignSystem
import UIKit

/// "View all ›" under each of Discover's mosaic chunks: pushes the whole
/// mosaic — For You's `DiscoverGalleryViewController`, a profile's media
/// gallery (#631). In PostGrid since the profile lays out the same list
/// (`DiscoverListLayout`).
///
/// A plain secondary-label button in semibold subheadline, the chevron
/// trailing and pointing RIGHT because it pushes a screen.
///
/// Under the chunk rather than over it: the chunk is content, not a section
/// that needs a title to be understood, and the control belongs where the
/// eye arrives having looked through it. (The sound sheet's sections carry
/// a bare chevron after their title instead, `SectionTitleView`:
/// a row scrolls sideways, and there the head is where the eye starts.)
///
/// **Right-aligned, and close under the tiles** (2026-09-29): the chevron
/// ends on the chunk's right edge, where a row header's "›" ends, and the
/// title sits `titleTopInset` under the chunk's foot. The footer is laid
/// flush against the foot (`DiscoverListLayout.viewAllHeight`), and the
/// control keeps the footer's full 44pt height as its hit target while
/// drawing its title at the TOP of it: the rest of the height is the air
/// before the next card, so tightening the gap above cost the target nothing.
public final class DiscoverViewAllFooterView: UICollectionReusableView {
    public static let reuseID = "DiscoverViewAllFooterView"
    public static let title = "View all"
    /// Between the chunk's foot and the top of the title's line.
    public static let titleTopInset: CGFloat = 6
    /// What VoiceOver says the control does. For You's by default; a host
    /// whose mosaic is something else says so (the profile's is its media).
    public static let defaultAccessibilityHint = "Shows every post in Discover's mosaic"

    public var onTap: (() -> Void)?

    /// VoiceOver's hint — see `defaultAccessibilityHint`.
    public var controlAccessibilityHint: String? {
        get { button.accessibilityHint }
        set { button.accessibilityHint = newValue }
    }

    private let button = UIButton(configuration: .plain())

    override public init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 12, weight: .bold)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Spacing.xs + 2
        configuration.baseForegroundColor = .secondaryLabel
        // No trailing inset, so the chevron ends on the chunk's edge; a
        // leading one, so the target reaches a little past the words' start.
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: Self.titleTopInset, leading: Spacing.md, bottom: 0, trailing: 0
        )
        var text = AttributedString(Self.title)
        text.font = UIFont.scaledFont(forTextStyle: .subheadline, weight: .semibold)
        configuration.attributedTitle = text
        button.configuration = configuration
        button.contentHorizontalAlignment = .trailing
        button.contentVerticalAlignment = .top
        button.accessibilityHint = Self.defaultAccessibilityHint
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
        button.accessibilityHint = Self.defaultAccessibilityHint
    }

    /// Presses the control, as a tap would.
    public func sendTap() { onTap?() }

    #if DEBUG
    /// The control's frame — its hit target — in this view's space.
    public var debugControlFrame: CGRect { button.frame }
    /// Its title's frame, in this view's space.
    public var debugTitleFrame: CGRect? {
        button.titleLabel.map { $0.convert($0.bounds, to: self) }
    }
    #endif
}
