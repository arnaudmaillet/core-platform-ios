import DesignSystem
import UIKit

/// A section header with an action on its trailing edge — "Recent" and the
/// "Clear all" that empties it.
///
/// Composes `SectionHeaderPillButton` rather than extending it: the pill
/// keeps owning how a header looks (the app's one section title,
/// `SectionTitleView`) and how it morphs when it pins; this owns what sits
/// beside it. A pinned capsule cannot carry a trailing accessory the way a
/// flow title can (`SectionTitleView.trailingAccessory`), so the action
/// stays a sibling of the pill, on the same surface inset from the far edge.
final class ExploreSectionHeaderView: UICollectionReusableView {
    /// Fires when the trailing action is tapped. Re-assigned on every
    /// configure, since the view is reused across sections.
    var onAction: (() -> Void)?

    private let pill = SectionHeaderPillButton()
    private let actionButton = UIButton(type: .system)
    private var actionTrailing: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.pinAsHeader(in: self)

        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        actionButton.configuration = configuration
        actionButton.addAction(
            UIAction { [weak self] _ in self?.onAction?() }, for: .primaryActionTriggered
        )
        // Centred on the PILL, not on this view: the pill floats from the
        // header's top, and the header's bottom carries the title-to-rows
        // gap — centring on the container would leave the action riding low.
        let trailing = trailingAnchor.constraint(
            equalTo: actionButton.trailingAnchor, constant: SectionTitleView.Metrics.surfaceInset
        )
        actionTrailing = trailing
        actionButton.constrain(in: self) { _ in
            trailing
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

    override func layoutSubviews() {
        pill.alignToSurface()
        let trailing = SectionTitleView.surfaceInsets(of: self).trailing
        if actionTrailing?.constant != trailing { actionTrailing?.constant = trailing }
        super.layoutSubviews()
    }

    /// `actionTitle` nil hides the trailing button, so a section without an
    /// action is just a header.
    func configure(title: String?, actionTitle: String? = nil) {
        pill.setPillTitle(title)

        actionButton.isHidden = actionTitle == nil
        guard let actionTitle else { return }
        var attributes = AttributeContainer()
        attributes.font = .appFont(forTextStyle: .subheadline)
        actionButton.configuration?.attributedTitle = AttributedString(actionTitle, attributes: attributes)
    }
}
