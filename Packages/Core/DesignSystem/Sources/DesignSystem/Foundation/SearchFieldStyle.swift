import UIKit

/// Every search field's leading glyph is the owner's magnifier, `core.search`
/// (#2456), not the system's `magnifyingglass`.
///
/// ONE PLACE SETS IT, as `SwitchStyle` does for the switches: an appearance
/// rule at launch reaches every `UISearchBar` built after it — the Messages
/// inbox, the relationship lists, the countries shop, the map's filter sheet,
/// Search, the share sheet and the sticker picker — with no screen setting it
/// by hand. A screen that wants another glyph calls `setImage(_:for:state:)`
/// on its own bar; an instance value outranks the appearance default.
///
/// ⚠️ Where the system draws the field itself (the search tab's field once
/// it moves into the bottom bar on iOS 26 and 27), it may keep its own glyph;
/// nothing is forced there by hand-built views.
public enum SearchFieldStyle {
    /// The glyph at the field's text size: the body style, as the field's
    /// own text.
    public static var glyph: UIImage? {
        AppSymbol.search.image(UIImage.SymbolConfiguration(textStyle: .body, scale: .small))
    }

    /// Call once, before any view is built (`SceneDelegate`, beside
    /// `SwitchStyle.tintAppWide()`).
    public static func magnifierAppWide() {
        UISearchBar.appearance().setImage(glyph, for: .search, state: .normal)
    }
}
