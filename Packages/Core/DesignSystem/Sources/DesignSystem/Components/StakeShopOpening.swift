import UIKit

/// Whoever can build the Shop opened on its Boosts — the sheet the stake
/// menu's empty-pack row ("Get ×100 cartridges in the Shop") opens.
///
/// Adopted by the shell's tab bar controller, which owns the one way to build
/// the Shop (`AppContainer.makeStakeShopSheet`, the same
/// `CountryShopViewController.sheet` the Explore header and the points sheet
/// present). It is found UP THE RESPONDER CHAIN from the control the menu was
/// raised on (`StakeShop.openAction(from:)`), so the rail, the composer and
/// every card reach it without a closure threaded through each screen that
/// draws them: a view's chain climbs its view controllers, then each
/// presented controller's presenter, to the window's root.
@MainActor
public protocol StakeShopOpening: AnyObject {
    /// The Shop as a sheet, on its Boosts; nil when nothing sells packs (the
    /// fleet, until the backend carries them).
    func makeStakeShop() -> UIViewController?
}

/// Opening the Shop from a stake control: the opener up its responder chain,
/// presenting over whatever is on top.
@MainActor
public enum StakeShop {
    /// The first `StakeShopOpening` up `source`'s responder chain.
    public static func opener(from source: UIResponder) -> (any StakeShopOpening)? {
        sequence(first: source, next: \.next).lazy.compactMap { $0 as? any StakeShopOpening }.first
    }

    /// The empty-pack row's action from `source`: opens the Shop over the top
    /// of what is presented. Nil when no opener is up the chain — the row
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

    /// Builds the Shop and presents it from the TOP of the presentation stack
    /// over `source`'s window — over a full-screen feed, a post's sheet or the
    /// points sheet alike, so it lands on what the viewer is looking at.
    /// Returns the presenter, nil when nothing was presented.
    @discardableResult
    static func open(with opener: any StakeShopOpening, from source: UIResponder) -> UIViewController? {
        guard let root = rootViewController(of: source) ?? (opener as? UIViewController),
              let shop = opener.makeStakeShop() else { return nil }
        let presenter = topPresenter(over: root)
        presenter.present(shop, animated: true)
        return presenter
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
