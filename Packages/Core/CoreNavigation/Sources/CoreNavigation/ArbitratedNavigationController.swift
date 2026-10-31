import DesignSystem
import UIKit

/// A chevron-back stack whose back button closes through its arbiter (#1144).
///
/// UIKit's own back button pops whatever is on top, and a second tap while
/// the first pop runs pops again: two quick taps on Download Your Data landed
/// on Settings, two screens down, in one 0.3 s transition (simulator,
/// 2026-10-31). Each screen's `backAction` closes THAT screen instead: a
/// second tap finds the close pending and is dropped, and a tap during a back
/// swipe closes the screen only if the swipe was abandoned.
open class ArbitratedNavigationController: ChevronBackNavigationController {
    override open func screenJoins(_ viewController: UIViewController) {
        super.screenJoins(viewController)
        StackArbiter.adoptBackButton(of: viewController)
    }
}

public extension StackArbiter {
    /// `screen`'s back button closes `screen` through its stack's arbiter,
    /// once — never the screen on top at the time of the tap. Public API
    /// (`UINavigationItem.backAction`); the long-press history menu and the
    /// back swipes are untouched.
    static func adoptBackButton(of screen: UIViewController) {
        guard screen.navigationItem.backAction == nil else { return }
        screen.navigationItem.backAction = UIAction { [weak screen] _ in
            screen?.closeScreen()
        }
    }
}
