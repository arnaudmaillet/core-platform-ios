import UIKit

/// Entry point contract for the Settings feature (#2382). The app shell and
/// the profile depend on this interface package — never on the Settings
/// implementation — and the composition root wires the one builder.
@MainActor
public protocol SettingsFeatureBuilding {
    /// The signed-in viewer's Settings, pushed from the own profile's gear.
    /// `onLogout` is the shell's: Log Out, and what a deleted or deactivated
    /// account leaves behind.
    func makeSettingsViewController(onLogout: @escaping () -> Void) -> UIViewController

    /// Settings for a guest (guest mode): only what works without an account
    /// — the app-wide section (preferences, help, legal) — with "Log in or sign
    /// up", which calls `onSignIn`, where Log Out would be.
    func makeGuestSettingsViewController(onSignIn: @escaping () -> Void) -> UIViewController

    /// The screen that accepts a family supervision invite (#417), opened by
    /// a `core-platform.click/family/<code>` link with the code filled in.
    /// Nothing is linked until the viewer confirms there.
    func makeSupervisionAcceptViewController(code: String) -> UIViewController

    /// Settings → Family and Teens, opening the supervision with
    /// `otherAccountID` once the page has it (#1106) — a supervision
    /// notification's destination.
    func makeFamilyAndTeensViewController(openingSupervisionWith otherAccountID: String?) -> UIViewController

    /// Edit Profile → Account Type (personal, creator, business).
    func makeAccountTypeViewController() -> UIViewController

    /// Edit Profile → who sees the followers and following lists.
    func makeListPrivacyViewController() -> UIViewController

    /// Offers a passkey once a session has landed (#840): after a sign-up,
    /// and after a sign-in while the account has none, at most once every
    /// 30 days. Over `host`'s screen when it is due; `completion` runs once
    /// the offer is settled or skipped, so whatever comes next waits for it.
    func presentPasskeyOfferIfDue(
        on host: @escaping () -> UIViewController?,
        afterSignUp: Bool,
        completion: @escaping () -> Void
    )
}

/// A Settings screen that opens one of its sections by name: the
/// `-open-settings <section>` launch argument's second step (QA), where the
/// name is a section's raw value (account, security, privacy, legal…).
@MainActor
public protocol SettingsSectionOpening: AnyObject {
    /// Pushes the section named `name`. False when no section has that name.
    @discardableResult
    func openSection(named name: String) -> Bool
}
