import CoreModels
import UIKit

/// Where the profile's gallery filter tray is hosted.
///
/// Not a style choice — the two are mutually exclusive for a hard UIKit reason.
/// The tray normally rides the navigation controller's toolbar, which iOS
/// positions against the *window's* bottom safe area and gives a zeroed safe
/// area of its own. Below a `UITabBarController` that lands the tray inside the
/// tab bar's band, and no inset, margin or additional-safe-area applied from
/// outside moves it (all three measured). A screen that keeps a tab bar beneath
/// it therefore has to host the tray itself.
public enum ProfileTrayPlacement: Sendable {
    /// In the navigation controller's toolbar. The default, and correct for
    /// every *pushed* profile — the tab bar is hidden under it, the toolbar owns
    /// the bottom of the screen, and the feed hand-off (which trades ownership
    /// of that shared toolbar) keeps working.
    case navigationToolbar
    /// In the screen's own view, pinned above `safeAreaLayoutGuide.bottom` —
    /// which, inside a tab bar controller, is the top of the tab bar. For a
    /// profile shown as a *tab root*, where the bar stays and must remain
    /// tappable. The same arrangement the map's filter bars use.
    case aboveBottomSafeArea
}

/// Entry point contract for the Profile feature. The app shell (and any feature
/// that wants to push a profile surface) depends on this interface package —
/// never on the Profile implementation — so editing Profile internals
/// recompiles nothing but Profile itself.
@MainActor
public protocol ProfileFeatureBuilding {
    /// The signed-in viewer's own profile, resolved from the active auth
    /// session.
    ///
    /// **`onLogout` doubles as the account-chrome switch.** Non-nil is the
    /// canonical entry point (the Profile tab root): the screen carries the
    /// settings gear and the profile switcher, and Log Out means what the shell
    /// says it means. Nil is a *routed* arrival — the "(Me)" row in a
    /// relationship list, a deep link — where the screen is the same profile but
    /// the account actions are withheld: switching accounts or logging out from
    /// inside a deep stack strands every screen below it on an identity that no
    /// longer applies. Those belong at one entry point, not wherever the graph
    /// happens to lead.
    ///
    /// The builder is told rather than inferring it. Stack depth is tempting now
    /// that the canonical entry point is a root — but a routed profile can be
    /// the root of a stack too (a `.profile` route firing into an empty tab), so
    /// depth would answer this wrong exactly where it matters.
    ///
    /// `identityStub` serves the same purpose here as on `makeProfileViewController`
    /// — letting the screen title itself before the profile load returns — and
    /// matters for routed arrivals, where the origin already has the handle.
    /// `trayPlacement` states what sits below this screen: `.navigationToolbar`
    /// for a pushed profile (the tab bar is hidden under it), and
    /// `.aboveBottomSafeArea` when it is a tab root and the bar stays.
    func makeCurrentUserProfileViewController(
        onLogout: (() -> Void)?,
        identityStub: ProfileIdentityStub?,
        trayPlacement: ProfileTrayPlacement
    ) -> UIViewController

    /// Any user's profile by id — the destination the router pushes when a
    /// profile route fires (e.g. tapping a post author). Carries no account
    /// actions; the nav stack's back button returns to the origin.
    /// `identityStub` is the origin's synchronously-known identity slice
    /// (handle, display name, follow state if known): it lets the screen
    /// compose its navigation chrome before the push animates. Pass nil when
    /// the origin only has the id.
    func makeProfileViewController(for profileID: ProfileID, identityStub: ProfileIdentityStub?) -> UIViewController

    /// The signed-in viewer's avatar, decoded and cached — for shell chrome
    /// (the Profile tab's icon). Best-effort: `nil` when the viewer has no
    /// avatar or it can't be fetched; callers render a placeholder glyph.
    func viewerAvatarImage() async -> UIImage?
}

public extension ProfileFeatureBuilding {
    /// Convenience for callers with nothing to seed — protocols can't carry
    /// default arguments, so the defaults live here.
    func makeCurrentUserProfileViewController(onLogout: @escaping () -> Void) -> UIViewController {
        makeCurrentUserProfileViewController(
            onLogout: onLogout, identityStub: nil, trayPlacement: .navigationToolbar
        )
    }

    /// The pushed-profile default. Every caller that does not say otherwise is
    /// pushing onto a stack whose tab bar is hidden, which is what the toolbar
    /// placement is for; only a tab root has to ask for something else.
    func makeCurrentUserProfileViewController(
        onLogout: (() -> Void)?,
        identityStub: ProfileIdentityStub?
    ) -> UIViewController {
        makeCurrentUserProfileViewController(
            onLogout: onLogout, identityStub: identityStub, trayPlacement: .navigationToolbar
        )
    }
}

/// Vends the switcher `UIMenu`. `reload()` pre-fetches + pre-formats the account
/// profiles so `makeMenu` is fully synchronous (its `UIAction`s render title +
/// subtitle together, no deferred load). Built and held by the profile header,
/// which is the one surface that offers switching now that the map avatar is gone.
@MainActor
public protocol ProfileSwitcherPresenting: AnyObject {
    /// Pre-fetch + pre-format the account's profiles.
    func reload() async
    /// A synchronous switcher menu built from the last `reload`.
    func makeMenu(onSwitch: @escaping () -> Void, onAddProfile: @escaping () -> Void) -> UIMenu
}

public extension Notification.Name {
    /// Posted after the viewer switches the active profile, so identity surfaces
    /// (the map avatar, an open profile screen) can refresh to the new profile.
    static let activeProfileDidChange = Notification.Name("cn.wynn.core-platform-ios.activeProfileDidChange")
}
