import DesignSystem
import UIKit

/// The engaged toolbar's trailing item: a sort selector for the comments
/// stream, taking the bookmark/share cluster's territory while comments
/// are engaged — the audio attribution stays anchored on the left, and
/// the yielded actions live in the engaged card (keep-and-stack: the bar
/// stays onstage, so its ITEMS are the context surface —
/// `setToolbarItems(_:animated:)` is the system's own morph).
///
/// A bar item custom view on the established contracts: 36pt tall (the
/// bar-bubble invariant — every bubble on the feed's bars renders 36pt so
/// the system glass capsules read as one family), content-hugging so the
/// platter wraps it flush, and the system wraps custom views in their own
/// Liquid Glass bubble by construction.
///
/// Selection is honest local state (menu checkmark + title follow the
/// chosen order); the ordering of the stream itself is a SEAM — the mock
/// BFF carries no comment ranking yet, so `onOrderChange` waits unwired,
/// exactly like the composer's `onAttachMedia`.
final class SnapCommentSortButton: UIButton {
    enum Order: String, CaseIterable {
        case recent = "Recent"
        case trending = "Trending"
    }

    private(set) var order: Order = .recent
    /// Fired on a genuine change (not re-selection). The sorting seam.
    var onOrderChange: ((Order) -> Void)?

    init() {
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "arrow.up.arrow.down")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePadding = Spacing.xs
        // SEMANTIC, never `.white`. The bar this rides carries the page's
        // theme (`SnapChromeTheme`, applied to the navigation bar itself so
        // UIKit draws the Liquid Glass platter from its traits), which is
        // `.dark` over media and UNSPECIFIED on a text post — where, in
        // light mode, hardcoded white put invisible glyphs on a light
        // platter. That is the exact failure `applyChromeTheme` was written
        // to prevent; this item was the one that never got the memo. Every
        // other bar item already reads `.label` (see `SnapNavControls` and
        // `SnapAuthorIdentityView`), so this joins them rather than
        // inventing a rule.
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: Spacing.sm, bottom: 0, trailing: Spacing.sm
        )
        configuration = config
        showsMenuAsPrimaryAction = true
        // 999, never required: the bar's item wrapper pins its own height
        // with autoresizing constraints — anything required loses to it
        // with a console break (the bars' shared doctrine).
        let height = heightAnchor.constraint(equalToConstant: 36)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        apply(order)
        // The pill's width is reserved for the LONGEST option up front:
        // the bar wrapper measures the custom view once, and a selection
        // that grows the title inside a stale platter wraps it to two
        // lines (observed with "Trending" in a "Recent"-sized bubble).
        // A stable floor means selection never re-negotiates the bar.
        let longest = Order.allCases
            .map { option -> CGFloat in
                var probe = configuration
                var title = AttributedString(option.rawValue)
                title.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
                probe?.attributedTitle = title
                let holder = UIButton(configuration: probe ?? .plain())
                return holder.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            }
            .max() ?? 0
        let width = widthAnchor.constraint(greaterThanOrEqualToConstant: longest.rounded(.up))
        width.priority = UILayoutPriority(999)
        width.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Selects an order: title and menu checkmark follow, the seam fires
    /// on genuine changes. Internal (not private) so the menu contract is
    /// unit-testable without driving UIKit's menu presentation.
    func select(_ new: Order) {
        let changed = new != order
        apply(new)
        if changed { onOrderChange?(new) }
    }

    /// Fresh engagements start at the default order — sort is engagement-
    /// scoped state, never carried from one post's comments to another's.
    func reset() {
        apply(.recent)
    }

    private func apply(_ new: Order) {
        order = new
        var config = configuration
        var title = AttributedString(new.rawValue)
        title.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        config?.attributedTitle = title
        configuration = config
        menu = UIMenu(options: .singleSelection, children: Order.allCases.map { option in
            UIAction(
                title: option.rawValue,
                state: option == new ? .on : .off
            ) { [weak self] _ in
                self?.select(option)
            }
        })
    }
}
