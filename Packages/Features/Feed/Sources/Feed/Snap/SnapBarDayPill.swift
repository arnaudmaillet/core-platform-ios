import DesignSystem
import UIKit

/// The engaged thread's day, in the nav bar left of the points (#757): the
/// day of the last chip gone under the header, as a conversation's bar shows
/// it (#755). A tap scrolls the thread to that day's chip.
///
/// ⚠️ A CUSTOM VIEW, BECAUSE IT IS THE ONE THAT GIVES WAY. A title item
/// cannot truncate: a run that does not fit is hidden whole behind a `•••`
/// (the bar's own rule, see `SnapBarPillWidths`). This pill takes the width
/// the run leaves it (`setMaxWidth`) and truncates its title in it, first of
/// everything on the bar — the owner's call, 2026-10-10.
final class SnapBarDayPill: UIButton {
    private var maxWidth: NSLayoutConstraint?

    init(title: String) {
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        var attributed = AttributedString(title)
        attributed.font = UIFont.scaledFont(forTextStyle: .footnote, weight: .semibold)
        config.attributedTitle = attributed
        // Semantic, never `.white`: the bar carries the page's theme (see
        // `SnapCommentSortButton`).
        config.baseForegroundColor = .label
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Spacing.sm, bottom: 0, trailing: Spacing.sm)
        configuration = config
        titleLabel?.lineBreakMode = .byTruncatingTail
        titleLabel?.numberOfLines = 1
        accessibilityLabel = title
        accessibilityHint = "Scrolls to the first comment of the day"
        // 999, never required: the bar's item wrapper pins its own height.
        let height = heightAnchor.constraint(equalToConstant: 36)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The most the pill may take; its title truncates inside it.
    func setMaxWidth(_ width: CGFloat) {
        let width = max(36, width)
        if let maxWidth {
            guard abs(maxWidth.constant - width) > 0.5 else { return }
            maxWidth.constant = width
        } else {
            let constraint = widthAnchor.constraint(lessThanOrEqualToConstant: width)
            constraint.priority = UILayoutPriority(999)
            constraint.isActive = true
            maxWidth = constraint
        }
        invalidateIntrinsicContentSize()
    }

    /// The width it is held to. Tests.
    var debugMaxWidth: CGFloat? { maxWidth?.constant }
}
