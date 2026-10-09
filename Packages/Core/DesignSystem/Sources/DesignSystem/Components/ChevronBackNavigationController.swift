import UIKit

/// A navigation stack whose back buttons are the chevron alone (#727).
///
/// iOS labels the back button with the previous screen's title, or "Back"
/// when that title does not fit; the app shows neither, anywhere. Rather than
/// count on every pushed screen to set `backButtonDisplayMode`, the stack
/// sets it on every screen it holds — the mode is read from the screen BELOW
/// the one showing, so each screen is marked as it joins the stack.
///
/// No delegate: a navigation delegate costs bar-hiding screens their
/// full-surface back swipe (see `NativePopGestureEnabler`), so the marking
/// rides the push and set calls instead.
open class ChevronBackNavigationController: UINavigationController {
    override public init(rootViewController: UIViewController) {
        super.init(rootViewController: rootViewController)
        Self.markChevronOnly(rootViewController)
    }

    override public init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    public convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    override open func pushViewController(_ viewController: UIViewController, animated: Bool) {
        topViewController.map(Self.markChevronOnly)
        Self.markChevronOnly(viewController)
        super.pushViewController(viewController, animated: animated)
    }

    override open var viewControllers: [UIViewController] {
        didSet { viewControllers.forEach(Self.markChevronOnly) }
    }

    override open func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        viewControllers.forEach(Self.markChevronOnly)
        super.setViewControllers(viewControllers, animated: animated)
    }

    /// The back button `viewController` lends the screen pushed over it:
    /// the chevron, no title.
    public static func markChevronOnly(_ viewController: UIViewController) {
        viewController.navigationItem.backButtonDisplayMode = .minimal
    }
}
