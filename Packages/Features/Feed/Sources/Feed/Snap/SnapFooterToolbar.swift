import DesignSystem
import UIKit

/// The text post's footer, as a composition the conversation screen builds
/// with its own leading item:
///
/// ```
///  [leading] ———————————————— [🔖 ⇄] [⋯]     the post: a pill, then space
///  [leading ————————————————] [🔖 ⇄] [⋯]     `leadingFills`: the emote strip
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
    ///
    /// `leadingFills`: `leading` draws its own capsule and stretches by Auto
    /// Layout over every point the trailing bubbles leave (lowest hugging, a
    /// huge lowest-priority width — see `ConversationThreadAccessory`). Its
    /// item hides the bar's shared bubble — a capsule in a bubble would be
    /// padded inside it, its content cut short of the visible ends — and a
    /// fixed space takes the flexible one's place, which would otherwise
    /// claim the room.
    static func items(
        leading: UIView, leadingFills: Bool = false, bookmark: UIButton, repost: UIButton, more: UIButton
    ) -> [UIBarButtonItem] {
        let shareCluster = UIStackView(arrangedSubviews: [bookmark, repost])
        shareCluster.axis = .horizontal
        let leadingItem = UIBarButtonItem(customView: leading)
        leadingItem.hidesSharedBackground = leadingFills
        return [
            leadingItem,
            leadingFills ? .fixedSpace(Spacing.sm) : .flexibleSpace(),
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
        let button = SnapNavControls.makeToolbarActionButton(systemName: PostActionSymbol.repost)
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
}
