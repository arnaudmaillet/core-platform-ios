import DesignSystem
import Testing
import UIKit
@testable import Auth

/// The sign-in sheet on the app's own buttons (#2020): each method an
/// `AppButton` at the form size, Apple's on its monochrome ground, the wait
/// the button's held load; every step's primary button an `AppButton`,
/// gated while its input is invalid.
@MainActor
struct AuthAppButtonTests {
    private static let methods = SignInMethod.all

    /// Each method's button carries its title, its symbol and its ground —
    /// Apple's monochrome, as its guidelines ask; the rest quiet cards.
    @Test func eachMethodIsAnAppButton() throws {
        let list = MethodSelectionViewController(methods: Self.methods)
        for method in Self.methods {
            let button = try #require(list.debugButton(for: method), "no button for \(method)")
            #expect(button.content.title == method.displayName)
            #expect(button.content.symbol == method.symbolName)
            #expect(button.size == .form)
            #expect(button.shape == .card)
            #expect(button.aspect == .pill(method == .provider(.apple) ? .monochrome : .quiet))
        }
        let apple = try #require(list.debugButton(for: .provider(.apple)))
        #expect(apple.content.title == "Continue with Apple")
        #expect(apple.content.symbol == "apple.logo")
    }

    /// The tap is the button's, and reports its method.
    @Test func aTapReportsTheMethod() throws {
        let list = MethodSelectionViewController(methods: Self.methods)
        var picked: [SignInMethod] = []
        list.onMethodSelected = { picked.append($0) }
        for method in Self.methods {
            try #require(list.debugButton(for: method)).sendActions(for: .primaryActionTriggered)
        }
        #expect(picked == Self.methods)
    }

    /// A running sign-in: its button in its held load, the others gated, ×
    /// disabled — and all of it cleared with nil.
    @Test func aRunningSignInHoldsItsButtonAndGatesTheRest() throws {
        let list = MethodSelectionViewController(methods: Self.methods)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: list)
        window.isHidden = false
        defer { window.isHidden = true }
        list.view.layoutIfNeeded()

        list.setWorking(.provider(.apple))
        for method in Self.methods {
            let button = try #require(list.debugButton(for: method))
            if method == .provider(.apple) {
                #expect(button.phase == .loading, "Apple's button does not hold its load")
                #expect(button.isEnabled, "the held button greyed out")
            } else {
                #expect(!button.isEnabled, "\(method) stayed tappable during the sign-in")
                #expect(button.phase == .content)
            }
        }
        #expect(!list.debugCloseItem.isEnabled, "× closed under a running sign-in")

        list.setWorking(nil)
        for method in Self.methods {
            let button = try #require(list.debugButton(for: method))
            #expect(button.phase == .content)
            #expect(button.isEnabled)
        }
        #expect(list.debugCloseItem.isEnabled)
    }

    /// No grey row highlight: the rows host their buttons on a clear ground
    /// and select nothing.
    @Test func theRowsSelectNothing() throws {
        let list = MethodSelectionViewController(methods: Self.methods)
        list.loadViewIfNeeded()
        let cell = list.tableView(list.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        #expect(cell.selectionStyle == .none)
        #expect(cell.contentView.subviews.contains { $0 is AppButton })
    }

    /// A step's primary button is an `AppButton`, gated while its input is
    /// invalid, held in its load while the call runs.
    @Test func aStepsPrimaryButtonIsGatedWhileItsInputIsInvalid() {
        let email = EmailEntryViewController()
        email.loadViewIfNeeded()
        #expect(email.primaryButton.size == .form)
        #expect(email.primaryButton.aspect == .pill(.prominent))
        #expect(!email.primaryButton.isEnabled, "Continue open on an empty address")

        email.debugEmailField.text = "not an address"
        email.debugEmailField.sendActions(for: .editingChanged)
        #expect(!email.primaryButton.isEnabled, "Continue open on an invalid address")

        email.debugEmailField.text = "nina@example.com"
        email.debugEmailField.sendActions(for: .editingChanged)
        #expect(email.primaryButton.isEnabled)

        email.setWorking(true)
        #expect(email.primaryButton.phase == .loading)
        email.setWorking(false)
        #expect(email.primaryButton.phase == .content)
        #expect(email.primaryButton.isEnabled)
    }

    /// The phone step's Continue, the same way.
    @Test func thePhoneStepsContinueIsAnAppButton() {
        let phone = PhoneAuthViewController()
        phone.loadViewIfNeeded()
        #expect(phone.debugContinueButton.size == .form)
        #expect(!phone.debugContinueButton.isEnabled, "Continue open with no number")
        phone.setWorking(true)
        #expect(phone.debugContinueButton.phase == .loading)
        phone.setWorking(false)
        #expect(phone.debugContinueButton.phase == .content)
    }
}
