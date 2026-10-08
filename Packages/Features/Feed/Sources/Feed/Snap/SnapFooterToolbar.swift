import DesignSystem
import UIKit

/// The text post's footer, as a composition the conversation screen builds
/// with its own leading item:
///
/// ```
///  [leading] ———————————————— [🔖 ⇄] [⋯]     the post: a pill, then space
///  [leading ————————————————————————] [⋯]     `leadingFills`, no actions:
///                                              a conversation's emote strip
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
    /// The bar's items, left to right. `actions` share one capsule between
    /// the leading item and ⋯ — the post's [🔖 ⇄]; none, and there is no
    /// capsule (a conversation: nothing there to save or repost).
    ///
    /// `leadingFills`: `leading` draws its own capsule and stretches by Auto
    /// Layout over every point the trailing bubbles leave (lowest hugging, a
    /// huge lowest-priority width — the text post composer's tool strip). Its
    /// item hides the bar's shared bubble — a capsule in a bubble would be
    /// padded inside it, its content cut short of the visible ends — and a
    /// fixed space takes the flexible one's place, which would otherwise
    /// claim the room.
    ///
    /// ⚠️ A fixed space ADDS to the gap UIKit already leaves between two glass
    /// groups (12pt on iOS 27: the feed's [🔖 ⇄] capsule stands 12 + 8 = 20pt
    /// from ⋯). So a filling leading item's separator is ZERO wide: it still
    /// splits the groups — ⋯ keeps its own bubble — and the strip runs to the
    /// bar's own 12pt gap, the gap every neighbouring bubble in the bar keeps
    /// (measured 2026-10-01: 20pt with `sm`, which read as a hole).
    static func items(
        leading: UIView, leadingFills: Bool = false, actions: [UIButton], more: UIButton
    ) -> [UIBarButtonItem] {
        let leadingItem = UIBarButtonItem(customView: leading)
        leadingItem.hidesSharedBackground = leadingFills
        var items: [UIBarButtonItem] = [
            leadingItem,
            leadingFills ? .fixedSpace(actions.isEmpty ? 0 : Spacing.sm) : .flexibleSpace(),
        ]
        if !actions.isEmpty {
            let cluster = UIStackView(arrangedSubviews: actions)
            cluster.axis = .horizontal
            items += [UIBarButtonItem(customView: cluster), .fixedSpace(Spacing.sm)]
        }
        return items + [UIBarButtonItem(customView: more)]
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
