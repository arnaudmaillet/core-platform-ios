import DesignSystem
import UIKit

/// "View all ›" under each of Discover's mosaic chunks: pushes the whole
/// mosaic (`DiscoverGalleryViewController`).
///
/// The sound sheet's sections' "View all" control in every respect the eye
/// reads (`SoundSheetSectionHeaderView`) — a plain secondary-label button in
/// semibold subheadline, the chevron trailing and pointing RIGHT because it
/// pushes a screen — so the app says "there is more of this" one way.
///
/// Under the chunk rather than over it: the chunk is content, not a section
/// that needs a title to be understood, and the control belongs where the
/// eye arrives having looked through it. (The sheet's sections carry theirs
/// at their titled head: a row scrolls sideways, and there the head is
/// where the eye starts.)
final class DiscoverViewAllFooterView: UICollectionReusableView {
    static let reuseID = "DiscoverViewAllFooterView"
    static let title = "View all"

    var onTap: (() -> Void)?

    private let button = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 12, weight: .bold)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Spacing.xs + 2
        configuration.baseForegroundColor = .secondaryLabel
        var text = AttributedString(Self.title)
        text.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        configuration.attributedTitle = text
        button.configuration = configuration
        button.contentHorizontalAlignment = .center
        button.accessibilityHint = "Shows every post in Discover's mosaic"
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    /// Presses the control, as a tap would.
    func sendTap() { onTap?() }
}
