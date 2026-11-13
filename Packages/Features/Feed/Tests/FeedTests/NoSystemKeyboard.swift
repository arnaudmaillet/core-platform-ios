import UIKit

extension UITextView {
    /// ⚠️ A FIELD FOCUSED IN A TEST MUST NOT RAISE THE SYSTEM KEYBOARD.
    ///
    /// The keyboard belongs to the simulator, not to the test's window. While
    /// it is up, it moves every window's `keyboardLayoutGuide` and posts
    /// unscoped keyboard notifications to every suite running beside this
    /// one. Resigning in a `defer` (#2396) still left it up for as long as the
    /// test ran. On a starved runner that was long enough for
    /// TextPostComposePageTests to lay out under it, with the same 213.67
    /// every time.
    ///
    /// An empty input view takes the keyboard's place: the field is focused,
    /// and nothing rises.
    func raisesNoKeyboard() {
        inputView = UIView(frame: .zero)
    }
}
