import Foundation
import UIKit

/// The shell's tab bar: three places in ONE CENTRED BUBBLE (#2579, the owner
/// 2026-11-26). The "+" left the bar for Explore's top bar (`CreateBarItem`,
/// #2489), and Profile no longer stands apart: the bubble is the only layout.
///
/// ```
/// a member    [ Explore · Messages · Profile ]
/// a guest     [ Explore · Settings ]            (Settings is the Profile tab)
/// ```
///
/// iOS 27 detaches the tab `prominentTabIdentifier` names, so the shell names
/// none (`drawAsOneBubble`). iOS 26 has no such property and detaches only a
/// `UISearchTab`, by its type: with none in the bar, it draws one bubble too.
@MainActor
public enum ShellTabs {
    /// The places in the bar, in bar order. ⚠️ Messages LEAVES a guest's bar
    /// (#626), it is not greyed out; a route to it asks them to sign up. The
    /// order never changes, so `-select-tab N` keeps naming the same places.
    public nonisolated static func tabs(isMember: Bool) -> [AppTab] {
        AppTab.allCases.filter { isMember || $0 != .messages }
    }

    /// Names no tab in iOS 27's `prominentTabIdentifier`, so every tab of
    /// `controller` shares one bubble, a member's three as a guest's two.
    /// Nothing on iOS 26, which has no such property (see the type's note).
    ///
    /// ⚠️ **AN iOS 27 SDK API, AND CI STILL BUILDS WITH XCODE 26.** Its SDK
    /// does not declare `prominentTabIdentifier`, so `#available` alone does
    /// not compile there. Built with an iOS 27 SDK (Swift 6.4), the call is
    /// typed; built without one, the same public setter is reached by name,
    /// and still runs on an iOS 27 device.
    public static func drawAsOneBubble(_ controller: UITabBarController) {
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            controller.prominentTabIdentifier = nil
        }
        #else
        let setter = NSSelectorFromString("setProminentTabIdentifier:")
        if controller.responds(to: setter) {
            _ = controller.perform(setter, with: nil)
        }
        #endif
    }
}
