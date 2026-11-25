import Foundation
import LaunchArguments
import UIKit

/// The shell's tab bar (#2489, the owner 2026-11-18): three places and how
/// they stand. The "+" left the bar for Explore's top bar (`CreateBarItem`).
///
/// ```
/// default            [ Explore · Messages ]   ( Profile )
/// -tabbar-grouped    [ Explore · Messages · Profile ]
/// a guest            [ Explore ]   ( Settings )     (Settings is the Profile tab)
/// ```
///
/// ⚠️ **iOS 26 GROUPS ALL THREE EITHER WAY.** Its bar detaches a tab by its
/// TYPE only, a `UISearchTab`, and Profile stays a plain `UITab`: a search
/// tab's identifier is the system's (`"search"`), which would break the
/// routes and Profile's hold. `prominentTabIdentifier`, which detaches any
/// tab it names, is iOS 27's.
@MainActor
public enum ShellTabs {
    /// Where Profile stands.
    public enum Layout: Sendable, Equatable {
        /// Profile in a bubble of its own at the trailing edge (iOS 27).
        case profileApart
        /// The three places in one bubble: `-tabbar-grouped`.
        case grouped
    }

    /// The layout this launch asked for. Read once, by the shell, at launch.
    public nonisolated static func layout(arguments: [String] = ProcessInfo.processInfo.arguments) -> Layout {
        LaunchArgument.tabBarGrouped.isPassed(in: arguments) ? .grouped : .profileApart
    }

    /// The places in the bar, in bar order. ⚠️ Messages LEAVES a guest's bar
    /// (#626), it is not greyed out; a route to it asks them to sign up. The
    /// order never changes, so `-select-tab N` keeps naming the same places.
    public nonisolated static func tabs(isMember: Bool) -> [AppTab] {
        AppTab.allCases.filter { isMember || $0 != .messages }
    }

    /// The tab drawn apart, or nil for one bubble. A guest's Settings is the
    /// Profile tab re-dressed, so it stands apart as Profile does.
    public nonisolated static func prominentTab(in layout: Layout) -> AppTab? {
        switch layout {
        case .profileApart: .profile
        case .grouped: nil
        }
    }

    /// Names the tab `layout` draws apart on `controller` — iOS 27's
    /// `prominentTabIdentifier`. Nothing on iOS 26, which has no such
    /// property (see the type's note).
    ///
    /// ⚠️ **AN iOS 27 SDK API, AND CI STILL BUILDS WITH XCODE 26.** Its SDK
    /// does not declare `prominentTabIdentifier`, so `#available` alone does
    /// not compile there. Built with an iOS 27 SDK (Swift 6.4), the call is
    /// typed; built without one, the same public setter is reached by name,
    /// and still runs on an iOS 27 device.
    public static func applyProminence(_ layout: Layout, to controller: UITabBarController) {
        let identifier = prominentTab(in: layout)?.rawValue
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            controller.prominentTabIdentifier = identifier
        }
        #else
        let setter = NSSelectorFromString("setProminentTabIdentifier:")
        if controller.responds(to: setter) {
            _ = controller.perform(setter, with: identifier)
        }
        #endif
    }
}
