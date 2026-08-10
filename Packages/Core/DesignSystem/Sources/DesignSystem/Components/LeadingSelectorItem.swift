import UIKit

/// Hosting a `PagedTabBar` in the navigation bar's LEADING item group instead of
/// its centre title slot.
///
/// The layout every host gets:
///
/// ```
/// [ back / leading icon ] [ selector capsule ]  ——— flexible ———  [ actions ]
/// ```
///
/// One implementation, four hosts. The pattern is four lines that all have to be
/// right together — bare rendering, a sized host, a cleared title slot, and a
/// leading group that supplements rather than replaces — and a host that gets
/// three of them looks correct while behaving wrongly.
public extension UINavigationItem {
    /// Moves `bar` out of the title slot and into the leading group.
    ///
    /// Returns the item, because a host that hides its selector (the profile,
    /// whose header owns the un-scrolled state) needs it: hiding the BAR leaves
    /// UIKit's capsule behind as an empty pill, and only
    /// `UIBarButtonItem.isHidden` takes the capsule with it.
    @discardableResult
    func installLeadingSelector(_ bar: PagedTabBar) -> UIBarButtonItem {
        // ⚠️ BARE. UIKit wraps a bar item's custom view in the system's glass
        // capsule — "bar items get a capsule, the title slot gets nothing" — so a
        // bar carrying its own backdrop here is a glass lens inside a glass
        // capsule, which is the arrangement that cost the lens its edge entirely.
        // See `PagedTabBar.suppressesBackdrop`.
        bar.suppressesBackdrop = true

        // ⚠️ A SIZED host, not the bar handed to the item directly. A bar item's
        // custom view with no resolved size draws at zero and takes no touches,
        // and the two states are pixel-identical — the same failure a bare
        // `UIButton` accessory has in a list cell. `PagedTabBar` states both
        // dimensions through `intrinsicContentSize`; pinning all four edges is
        // what passes them to the host.
        let host = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        // The centre is left EMPTY, so the space between the groups stays
        // flexible for whatever a host wants to put there later.
        titleView = nil

        // ⚠️ SUPPLEMENTS. A leading item that replaces the back button silently
        // disables the navigation controller's interactive pop gesture — the
        // reason the feed once had to build a whole replacement pan. Harmless on
        // a tab root, where there is no back button to supplement.
        leftItemsSupplementBackButton = true

        let item = UIBarButtonItem(customView: host)
        var leading = leftBarButtonItems ?? []
        // Whatever the host already put here keeps its place at the front: the
        // compose glyph on For You, the switcher on an own profile.
        leading.append(item)
        leftBarButtonItems = leading
        return item
    }
}
