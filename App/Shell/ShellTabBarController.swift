import UIKit

/// The shell's tab bar controller, with one addition: it reports its layout
/// passes.
///
/// The Profile tab's long-press menu is carried by an invisible button the shell
/// keeps aligned over the tab (see `MainTabCoordinator`). That tab's button view
/// belongs to UIKit and moves whenever the bar lays out — rotation, a size-class
/// change, the bar hiding and coming back — so the overlay needs a hook to
/// follow it. `UITabBarController` publishes none, hence this.
final class ShellTabBarController: UITabBarController {
    /// Called after every layout pass.
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}
