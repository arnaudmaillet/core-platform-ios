import CoreModels
import UIKit

/// Entry point contract for the Profile feature. The app shell (and any feature
/// that wants to push a profile surface) depends on this interface package —
/// never on the Profile implementation — so editing Profile internals
/// recompiles nothing but Profile itself.
@MainActor
public protocol ProfileFeatureBuilding {
    /// The signed-in viewer's own profile, resolved from the active auth
    /// session. `onLogout` is invoked when the user taps Log Out; the shell
    /// owns what that means (tearing down the authenticated scene).
    func makeCurrentUserProfileViewController(onLogout: @escaping () -> Void) -> UIViewController

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

    /// Presents the profile switcher as an action sheet from `presenter`,
    /// anchored to `sourceView` (the map avatar) — the reliable native
    /// presentation for the avatar's long-press, where a `UIMenu` can't be shown
    /// programmatically. Lists the account's profiles (active one marked) and
    /// "Add Profile". `onSwitch` fires after the active profile changes;
    /// `onAddProfile` when "Add Profile" is tapped. A switch also broadcasts
    /// `.activeProfileDidChange` so identity chrome (the map avatar) can refresh.
    func presentProfileSwitcher(
        from presenter: UIViewController,
        sourceView: UIView,
        onSwitch: @escaping () -> Void,
        onAddProfile: @escaping () -> Void
    )
}

public extension Notification.Name {
    /// Posted after the viewer switches the active profile, so identity surfaces
    /// (the map avatar, an open profile screen) can refresh to the new profile.
    static let activeProfileDidChange = Notification.Name("cn.wynn.core-platform-ios.activeProfileDidChange")
}
