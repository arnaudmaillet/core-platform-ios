import Testing
import UIKit

/// A field focused under `raisesNoKeyboard()` leaves the app's keyboard guide
/// where it was: another window's screen lays out as if no keyboard were up.
@MainActor
struct NoSystemKeyboardTests {
    @Test func aFocusedFieldThatRaisesNoKeyboardMovesNoOtherWindowsGuide() async throws {
        let screen = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.isHidden = false
        defer { window.isHidden = true }
        screen.view.layoutIfNeeded()
        let resting = screen.view.keyboardLayoutGuide.layoutFrame

        let other = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let field = UITextView(frame: CGRect(x: 0, y: 700, width: 390, height: 44))
        field.raisesNoKeyboard()
        other.addSubview(field)
        other.makeKeyAndVisible()
        defer {
            field.resignFirstResponder()
            other.isHidden = true
        }
        field.becomeFirstResponder()
        try #require(field.isFirstResponder)
        // Long enough for a system keyboard's arrival animation to land.
        for _ in 0..<60 { try await Task.sleep(for: .milliseconds(10)) }
        screen.view.layoutIfNeeded()
        let guide = screen.view.keyboardLayoutGuide.layoutFrame
        #expect(guide.height <= resting.height + 0.5, "a keyboard rose: \(resting) → \(guide)")
    }
}
