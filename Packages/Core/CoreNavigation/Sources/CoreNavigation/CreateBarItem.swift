import DesignSystem
import UIKit

/// The "+" in Explore's top bar, just inboard of search (#2489, the owner
/// 2026-11-18): `[bell] … [+][search]`. A guest's is "Sign in" in its place.
///
/// It was the tab bar's detached trailing item until then, a `UISearchTab`
/// re-dressed as a "+" whose tap was refused and answered by a menu opened
/// from an invisible anchor laid over its bubble. A bar item needs none of
/// that: it is a stock icon item (`BarItems.icon`, the bar contract #1679)
/// whose own `UIMenu` UIKit opens and anchors on a tap. Beside search, two
/// stock items, it shares search's platter.
///
/// **No hold.** The tab's hold armed the camera; a bar item whose tap opens a
/// menu has no native second gesture, so the camera stays the menu's first
/// entry instead.
///
/// **One item for both viewers, changed in place (R3, #2331):** the "+" with
/// its menu for a member, the owner's login door (#2434), prominent in the
/// primary, for a guest. A sign-in or a sign-out re-dresses the SAME
/// instance, so the bar redraws this item alone.
@MainActor
public final class CreateBarItem {
    /// By function (R2): Explore's create item, a member's or a guest's.
    public static let identifier = "explore.create"

    /// The item. Explore's trailing group places it (`trailingGroup`).
    public let item: UIBarButtonItem
    /// What the menu offers, in order.
    public let destinations: [CreateDestination]
    /// Whether it is a guest's "Sign in" rather than the "+".
    public private(set) var isSignIn = false

    private let menu: UIMenu
    private let signInAction: UIAction

    /// - Parameters:
    ///   - open: a member's pick in the menu.
    ///   - signIn: a guest's tap: the sign-up / sign-in sheet.
    public init(
        destinations: [CreateDestination],
        open: @escaping @MainActor (CreateDestination) -> Void,
        signIn: @escaping @MainActor () -> Void
    ) {
        self.destinations = destinations
        let menu = UIMenu(children: Self.actions(destinations, open: open))
        self.menu = menu
        // No image on the action: a `UIAction`'s image is re-applied to its
        // item when it fires (R7).
        signInAction = UIAction { _ in signIn() }
        item = BarItems.icon(id: Self.identifier, image: Self.plusImage, label: Self.createLabel, menu: menu)
    }

    /// Explore's trailing group: search at the screen edge (`[0]`), this item
    /// just inboard of it.
    public func trailingGroup(search: UIBarButtonItem) -> [UIBarButtonItem] {
        [search, item]
    }

    /// Dresses the item as a guest's "Sign in" or a member's "+", in place.
    public func showSignIn(_ signIn: Bool) {
        guard signIn != isSignIn else { return }
        isSignIn = signIn
        // The tap's answer first, its face after: setting an action may
        // carry the action's own (empty) face onto the item.
        if signIn {
            item.menu = nil
            item.primaryAction = signInAction
        } else {
            item.primaryAction = nil
            item.menu = menu
        }
        item.title = nil
        // ⚠️ Through `AppSymbol`: `UIImage(systemName:)` never finds the
        // app's own symbol, and the item would go blank.
        item.image = signIn ? AppSymbol.login.image() : Self.plusImage
        item.style = signIn ? .prominent : .plain
        // Said outright: a bar item does not refresh everything one change
        // touches (the #547 family), and VoiceOver read a stale name.
        item.accessibilityLabel = signIn ? Self.signInLabel : Self.createLabel
    }

    /// One action per destination, each opening its own.
    ///
    /// Icon AND label on every row: `preferredElementSize = .small` drops the
    /// labels but keeps the menu's standard width (~247pt of a 402pt
    /// screen), the three glyphs spread across it — measured on the tab's
    /// menu, and nothing public sets a menu's width.
    static func actions(
        _ destinations: [CreateDestination], open: @escaping @MainActor (CreateDestination) -> Void
    ) -> [UIAction] {
        destinations.map { destination in
            UIAction(title: destination.title, image: UIImage.symbol(named: destination.symbolName)) { _ in
                open(destination)
            }
        }
    }

    static let createLabel = "Create"
    static let signInLabel = "Sign in"
    /// The "+" the tab wore.
    static var plusImage: UIImage? { UIImage(systemName: "plus") }
}
