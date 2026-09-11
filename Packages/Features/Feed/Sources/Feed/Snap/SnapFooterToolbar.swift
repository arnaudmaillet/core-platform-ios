import DesignSystem
import UIKit

/// The text post's footer, as a composition the conversation screen
/// (`-unified-thread`) builds with its own leading item:
///
/// ```
///  [leading] ———————————————— [🔖 ⇄] [⋯]
/// ```
///
/// Every item is a custom view, so iOS 26 gives each its own glass bubble; the
/// fixed space is what keeps [🔖 ⇄] and [⋯] two bubbles rather than one shared
/// platter.
///
/// ⚠️ The snap feed still builds the SAME composition itself, in
/// `SnapFeedViewController.configureToolbarItems` (pinned by
/// `SnapToolbarCompositionTests`); this mirrors it rather than feeding it. Moving
/// the feed onto this factory is the follow-up that makes the two one.
enum SnapFooterToolbar {
    /// The bar's items, left to right.
    static func items(leading: UIView, bookmark: UIButton, repost: UIButton, more: UIButton) -> [UIBarButtonItem] {
        let shareCluster = UIStackView(arrangedSubviews: [bookmark, repost])
        shareCluster.axis = .horizontal
        return [
            UIBarButtonItem(customView: leading),
            .flexibleSpace(),
            UIBarButtonItem(customView: shareCluster),
            .fixedSpace(Spacing.sm),
            UIBarButtonItem(customView: more),
        ]
    }

    static func makeSaveButton() -> UIButton {
        let button = SnapNavControls.makeToolbarActionButton(systemName: "bookmark")
        button.accessibilityLabel = "Save"
        return button
    }

    /// ⚠️ Drawn without an action — see the feed's note on why repost has no
    /// client path to publish one yet.
    static func makeRepostButton() -> UIButton {
        let button = SnapNavControls.makeToolbarActionButton(systemName: "arrow.2.squarepath")
        button.accessibilityLabel = "Repost"
        return button
    }

    static func makeMoreButton(menu: UIMenu) -> UIButton {
        let button = SnapNavControls.makeToolbarActionButton(systemName: "ellipsis")
        button.accessibilityLabel = "More actions"
        button.showsMenuAsPrimaryAction = true
        button.menu = menu
        return button
    }

    /// What the leading item may take on a bar `barWidth` wide: the bar less
    /// its margins, the two trailing bubbles with their glass padding, the
    /// fixed space and a breath of flexible space.
    ///
    /// The padding is MEASURED, not published (~18pt per custom item — the
    /// same figure the feed's nav arithmetic is calibrated against), and the
    /// cost of getting it wrong is the whole bar collapsing into a `•••`.
    static func leadingWidthBudget(barWidth: CGFloat) -> CGFloat {
        let itemPadding: CGFloat = 18
        let barMargin: CGFloat = 16
        let bubble: CGFloat = 36
        let trailing = (bubble * 2 + itemPadding) + Spacing.sm + (bubble + itemPadding)
        return max(0, barWidth - barMargin * 2 - trailing - itemPadding - Spacing.sm)
    }
}
