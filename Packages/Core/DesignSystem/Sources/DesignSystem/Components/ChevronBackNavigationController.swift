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
/// rides the push and set calls instead — through `screenJoins(_:)`, which a
/// subclass extends (CoreNavigation's `ArbitratedNavigationController` gives
/// each screen's back button to the stack's arbiter, #1144).
open class ChevronBackNavigationController: UINavigationController {
    override public init(rootViewController: UIViewController) {
        super.init(rootViewController: rootViewController)
        screenJoins(rootViewController)
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
        topViewController.map(screenJoins)
        screenJoins(viewController)
        super.pushViewController(viewController, animated: animated)
    }

    override open var viewControllers: [UIViewController] {
        didSet { viewControllers.forEach(screenJoins) }
    }

    override open func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        viewControllers.forEach(screenJoins)
        super.setViewControllers(viewControllers, animated: animated)
    }

    /// Every screen, as it joins the stack (and again when it is re-set).
    open func screenJoins(_ viewController: UIViewController) {
        Self.markChevronOnly(viewController)
    }

    /// The back button `viewController` lends the screen pushed over it:
    /// the chevron, no title.
    public static func markChevronOnly(_ viewController: UIViewController) {
        viewController.navigationItem.backButtonDisplayMode = .minimal
    }
}
