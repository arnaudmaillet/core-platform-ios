import CoreModels
import UIKit

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
    /// canonical entry point (the Maps avatar): the screen carries the settings
    /// gear and the profile switcher, and Log Out means what the shell says it
    /// means. Nil is a *routed* arrival — the "(Me)" row in a relationship list,
    /// a deep link — where the screen is the same profile but the account
    /// actions are withheld: switching accounts or logging out from inside a
    /// deep stack strands every screen below it on an identity that no longer
    /// applies. Those belong at one entry point, not wherever the graph
    /// happens to lead.
    ///
    /// Note this cannot be inferred from `navigationController.viewControllers`:
    /// the canonical entry point is itself *pushed* (onto the Maps stack — the
    /// Profile tab no longer exists), so stack depth cannot tell the two apart.
    /// The builder is told.
    ///
    /// `identityStub` serves the same purpose here as on `makeProfileViewController`
    /// — letting the screen title itself before the profile load returns — and
    /// matters for routed arrivals, where the origin already has the handle.
    func makeCurrentUserProfileViewController(
        onLogout: (() -> Void)?,
        identityStub: ProfileIdentityStub?
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
    /// (the Maps nav-bar avatar button). Best-effort: `nil` when the viewer has
    /// no avatar or it can't be fetched; callers render a placeholder glyph.
    func viewerAvatarImage() async -> UIImage?

    /// The reusable profile switcher. The shell holds one for the map avatar's
    /// long-press context menu; the profile header builds its own. Nil when
    /// multi-profile switching isn't available. Call `reload()` up front so
    /// `makeMenu()` is synchronous when the menu is requested.
    func makeProfileSwitcher() -> ProfileSwitcherPresenting?
}

public extension ProfileFeatureBuilding {
    /// Convenience for callers with nothing to seed — protocols can't carry
    /// default arguments, so the default lives here.
    func makeCurrentUserProfileViewController(onLogout: @escaping () -> Void) -> UIViewController {
        makeCurrentUserProfileViewController(onLogout: onLogout, identityStub: nil)
    }
}

/// Vends the switcher `UIMenu`. `reload()` pre-fetches + pre-formats the account
/// profiles so `makeMenu` is fully synchronous (its `UIAction`s render title +
/// subtitle together, no deferred load) — the same menu on the profile header
/// and the map avatar's `UIContextMenuInteraction`.
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
