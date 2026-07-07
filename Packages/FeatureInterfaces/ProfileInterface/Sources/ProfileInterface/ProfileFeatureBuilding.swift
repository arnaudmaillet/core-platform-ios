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
    func makeProfileViewController(for profileID: ProfileID) -> UIViewController
}
