import DesignSystem
import UIKit

/// A section header with an action on its trailing edge — "Recent" and the
/// "Clear all" that empties it.
///
/// Composes `SectionHeaderPillButton` rather than extending it. The pill is
/// shared by five lists across three features and none of the others has a
/// trailing action; growing an optional accessory onto it would put a slot in
/// every one of them that only this screen fills. The pill keeps owning how a
/// header looks and how it morphs when it pins; this owns what sits beside it.
final class ExploreSectionHeaderView: UICollectionReusableView {
    /// Fires when the trailing action is tapped. Re-assigned on every
    /// configure, since the view is reused across sections.
    var onAction: (() -> Void)?

    private let pill = SectionHeaderPillButton()
    private let actionButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.pinAsHeader(in: self)

        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        actionButton.configuration = configuration
        actionButton.addAction(
            UIAction { [weak self] _ in self?.onAction?() }, for: .primaryActionTriggered
        )
        // Centred on the PILL, not on this view. The pill carries its own
        // float and, when a section follows another, an extra top margin — so
        // centring on the container would leave the action riding high above a
        // header that had shifted down.
        actionButton.constrain(in: self) { parent in
            actionButton.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
            actionButton.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
            actionButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: pill.trailingAnchor, constant: Spacing.sm
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
    }

    /// `leadsList` decides the header's top margin — see
    /// `SectionHeaderPillButton.setLeadsList`. `actionTitle` nil hides the
    /// trailing button, so a section without an action is just a header.
    func configure(title: String?, actionTitle: String? = nil, leadsList: Bool = true) {
        pill.setPillTitle(title)
        pill.setLeadsList(leadsList)

        actionButton.isHidden = actionTitle == nil
        guard let actionTitle else { return }
        var attributes = AttributeContainer()
        attributes.font = .preferredFont(forTextStyle: .subheadline)
        actionButton.configuration?.attributedTitle = AttributedString(actionTitle, attributes: attributes)
    }
}
