import UIKit

/// A pinned section's name in the navigation bar, after the leading item —
/// "New · 3", "Recent" — instead of a capsule pinned under the bar: the
/// Messages inbox's (#1301) and the post lists' (#1378), one look. A
/// system-titled glass bubble in the bar's own type, interactive.
///
/// ⚠️ ONE ITEM PER SECTION AND COUNT, EACH WITH ITS OWN IDENTIFIER: a title
/// edited in place swaps in a frame (and the bar freezes an item's width,
/// `ios27-bar-item-width-traps`), while a new item under a new identifier
/// gets UIKit's Liquid Glass morph — "New · 4" becoming "Recent" is that
/// morph.
@MainActor
public enum SectionBarItem {
    /// - Parameters:
    ///   - count: shown after the title, "Title · n"; zero for none.
    ///   - countNoun: what the count counts, for VoiceOver ("unread", "new").
    ///   - scope: the identifier's prefix, one per screen.
    ///   - onTap: what tapping the section's header did — its first row
    ///     under the bar.
    public static func make(
        title: String, count: Int, countNoun: String, scope: String, onTap: @escaping () -> Void
    ) -> UIBarButtonItem {
        let label = count > 0 ? "\(title) · \(count.formatted())" : title
        let item = UIBarButtonItem(title: label, image: nil, primaryAction: UIAction { _ in onTap() })
        item.identifier = "\(scope).section.\(title).\(count)"
        item.tintColor = .label
        // Its own glass, not a platter shared with the item before it.
        item.sharesBackground = false
        item.accessibilityLabel = count > 0 ? "\(title), \(count) \(countNoun)" : title
        item.accessibilityHint = "Scrolls to the \(title) section"
        return item
    }
}
