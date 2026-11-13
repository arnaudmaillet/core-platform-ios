import UIKit

/// Which window a keyboard notification is aimed at.
///
/// UIKit's own keyboard notifications never carry a window as their
/// `object`, so for them the scope is nil and every observer hears them, as
/// it always has. A TEST that fakes a keyboard posts it with its own window
/// as the object. The screens living in other test windows at the same
/// moment then ignore it. Swift Testing runs suites side by side, and on a
/// starved CI runner every test lasts minutes, so a fake keyboard posted
/// globally used to lift the composers of whatever else was on screen, for
/// the rest of their lives.
enum KeyboardNotificationScope {
    /// The window `note` is aimed at, or nil for a system notification.
    /// An identifier, not the window: it crosses into the main actor.
    nonisolated static func window(of note: Notification) -> ObjectIdentifier? {
        (note.object as? UIWindow).map(ObjectIdentifier.init)
    }
}

extension UIView {
    /// Whether a keyboard notification aimed at `scope` concerns this view.
    func hearsKeyboard(aimedAt scope: ObjectIdentifier?) -> Bool {
        guard let scope else { return true }
        return window.map(ObjectIdentifier.init) == scope
    }
}
