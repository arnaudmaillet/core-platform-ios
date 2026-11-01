import UIKit

/// The sign-in sheets' bar items, one look for the method list and the form
/// (#1969, #2022): ? leading — the help, not wired yet, so a tap does nothing
/// — and the system × trailing.
///
/// On the FORM (`ContentFittingNavigationController.applyFormBar`), every
/// step wears × on the right; on the left, ? on the form's root and on a step
/// with no way back (`AuthFormStep.offersWayBack`), the native back chevron
/// everywhere else — never both, since a leading item would replace the back.
@MainActor
enum AuthFormBar {
    static let helpIdentifier = "auth.form.help"
    static let closeIdentifier = "auth.form.close"

    static func makeHelpItem(identifier: String = helpIdentifier, action: @escaping () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "questionmark"), primaryAction: UIAction { _ in action() })
        item.identifier = identifier
        item.accessibilityIdentifier = identifier
        item.accessibilityLabel = "Help"
        return item
    }

    static func makeCloseItem(identifier: String = closeIdentifier, action: @escaping () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in action() })
        item.identifier = identifier
        item.accessibilityIdentifier = identifier
        item.accessibilityLabel = "Close"
        return item
    }

    /// Whether a step's leading slot is ? rather than the back chevron: the
    /// form's root, or a step with no way back. Pure.
    nonisolated static func leadsWithHelp(isRoot: Bool, offersWayBack: Bool) -> Bool {
        isRoot || !offersWayBack
    }
}

/// A form step that can have no way back (#2022): profile setup, once the
/// account exists. A step that does not conform offers its way back.
@MainActor
protocol AuthFormStep: AnyObject {
    var offersWayBack: Bool { get }
}
