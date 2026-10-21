import UIKit

/// Whoever can build the Shop opened on its Boosts — the screen the stake
/// menu's empty-pack row ("Get ×100 cartridges in the Shop") pushes.
///
/// Adopted by the shell's tab bar controller, which owns the one way to build
/// the Shop (`AppContainer.makeStakeShopScreen`, the same
/// `CountryShopViewController.storefront` the Rewards sheet's Shop tile
/// pushes). It is found UP THE RESPONDER CHAIN from the control the menu was
/// raised on (`StakeShop.openAction(from:)`), so the rail, the composer and
/// every card reach it without a closure threaded through each screen that
/// draws them: a view's chain climbs its view controllers, then each
/// presented controller's presenter, to the window's root.
@MainActor
public protocol StakeShopOpening: AnyObject {
    /// The Shop's screen, on its Boosts; nil when nothing sells packs (the
    /// fleet, until the backend carries them).
    func makeStakeShop() -> UIViewController?
}

/// Opening the Shop from a stake control: the opener up its responder chain,
/// pushing on the stack the viewer is looking at.
@MainActor
public enum StakeShop {
    /// The first `StakeShopOpening` up `source`'s responder chain.
    public static func opener(from source: UIResponder) -> (any StakeShopOpening)? {
        sequence(first: source, next: \.next).lazy.compactMap { $0 as? any StakeShopOpening }.first
    }

    /// The empty-pack row's action from `source`: pushes the Shop on the stack
    /// under what is presented. Nil when no opener is up the chain — the row
    /// then stays a disabled signpost (`StakeMenu.elements`).
    ///
    /// Resolved when the menu is BUILT (the control is on screen then) and
    /// run when the row is tapped, both weakly: a menu outliving its control
    /// opens nothing.
    public static func openAction(from source: UIResponder) -> (@MainActor () -> Void)? {
        guard let opener = opener(from: source) else { return nil }
        return { [weak opener, weak source] in
            guard let opener, let source else { return }
            open(with: opener, from: source)
        }
    }

    /// Builds the Shop and pushes it (`push(_:over:)`) over `source`'s
    /// window. Returns the stack it went on, nil when it went nowhere.
    @discardableResult
    static func open(with opener: any StakeShopOpening, from source: UIResponder) -> UINavigationController? {
        guard let root = rootViewController(of: source) ?? (opener as? UIViewController),
              let shop = opener.makeStakeShop() else { return nil }
        return push(shop, over: root)
    }

    /// Pushes `shop` — a screen of its own since 2026-10-13, not a sheet — on
    /// the navigation stack of the TOPMOST FULL-SCREEN context over `root`:
    /// the selected tab's, or a full-screen presentation's. Sheets over that
    /// context (the points sheet, a post's sheet) come down first, then the
    /// push, so it lands where the viewer is. Returns the stack, nil when
    /// there is none.
    @discardableResult
    public static func push(_ shop: UIViewController, over root: UIViewController) -> UINavigationController? {
        var context = root
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
            if [.fullScreen, .overFullScreen].contains(presented.modalPresentationStyle) { context = presented }
        }
        guard let stack = navigation(in: context) else { return nil }
        if let covering = context.presentedViewController, !covering.isBeingDismissed {
            context.dismiss(animated: true) { stack.pushViewController(shop, animated: true) }
        } else {
            stack.pushViewController(shop, animated: true)
        }
        return stack
    }

    /// The stack a push from `controller` goes on: a tab bar's selected
    /// tab's, the stack itself, its own stack, or the first a child holds.
    static func navigation(in controller: UIViewController?) -> UINavigationController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return navigation(in: tabs.selectedViewController) }
        if let stack = controller as? UINavigationController { return stack }
        if let stack = controller.navigationController { return stack }
        // A tab bar first: a shell's sibling (a side drawer) may hold a
        // stack of its own that is not where the viewer is.
        let children = controller.children.filter { $0 is UITabBarController }
            + controller.children.filter { !($0 is UITabBarController) }
        return children.lazy.compactMap { navigation(in: $0) }.first
    }

    /// The top of what is presented over `root`, skipping a controller on
    /// its way out (presenting from it would fail).
    public static func topPresenter(over root: UIViewController) -> UIViewController {
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private static func rootViewController(of source: UIResponder) -> UIViewController? {
        let view = (source as? UIView) ?? (source as? UIViewController)?.viewIfLoaded
        return view?.window?.rootViewController
    }
}
