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

    /// A row never clips its button — not when it appears, and not after the
    /// table lays out again (the list's sheet coming back after a form's
    /// closes), when the section rounds its rows once more (#2020, the
    /// owner's iPhone): the card stays a card, and a swell is not cut off.
    @Test func noRowClipsItsButtonEvenAfterARelayout() throws {
        let list = MethodSelectionViewController(methods: Self.methods)
        let rows = Self.buttonRows(of: list)
        #expect(rows.count == Self.methods.count)
        func check(_ moment: String) {
            for cell in rows {
                for view in [cell, cell.contentView] {
                    #expect(!view.clipsToBounds && view.layer.cornerRadius == 0 && view.layer.mask == nil, "\(moment)")
                }
            }
        }
        check("on appearing")
        // What the section does on a relayout: round and clip the row again
        // — on iOS 26+ through `cornerConfiguration` and the clipping flag.
        for cell in rows {
            cell.layer.cornerRadius = 25
            cell.cornerConfiguration = .corners(radius: .fixed(26))
            cell.clipsToBounds = true
            cell.layer.masksToBounds = true
            #expect(!cell.clipsToBounds && !cell.layer.masksToBounds, "the row clips again")
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
        }
        check("after a relayout")
    }

    /// The steps' buttons stand in the same rows.
    @Test func theStepsButtonsStandInUnclippedRows() {
        let phone = PhoneAuthViewController()
        let step = SignUpStepViewController(emoji: "🔑", title: "T", subtitle: "S", buttonTitle: "Continue")
        #expect(Self.buttonRows(of: phone).contains { phone.debugContinueButton.isDescendant(of: $0) })
        #expect(Self.buttonRows(of: step).contains { step.primaryButton.isDescendant(of: $0) })
    }

    /// Every button row a screen's table vends.
    private static func buttonRows(of screen: UITableViewController) -> [AuthButtonCell] {
        screen.loadViewIfNeeded()
        let table = screen.tableView!
        return (0..<screen.numberOfSections(in: table)).flatMap { section in
            (0..<screen.tableView(table, numberOfRowsInSection: section)).compactMap { row in
                screen.tableView(table, cellForRowAt: IndexPath(row: row, section: section)) as? AuthButtonCell
            }
        }
    }

    /// The list's sheet is opaque: no glass, no blur through it.
    @Test func theListsSheetIsOpaque() {
        let list = MethodSelectionViewController(methods: Self.methods)
        list.loadViewIfNeeded()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let color = list.tableView.backgroundColor?.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var white: CGFloat = 0
            var alpha: CGFloat = 0
            color?.getWhite(&white, alpha: &alpha)
            #expect(alpha == 1, "\(style) is not opaque")
            // The form's grey: light in the light, dark in the dark.
            #expect(style == .dark ? white < 0.2 : white > 0.9, "\(style) at \(white)")
        }
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

    /// The sheet in a window, on a stepped clock for its buttons' loads.
    private static func hostedList(_ time: ManualLoadingClock) -> (MethodSelectionViewController, UIWindow) {
        let list = MethodSelectionViewController(methods: methods, loadClock: time.clock)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: list)
        window.isHidden = false
        list.view.layoutIfNeeded()
        return (list, window)
    }

    /// A running sign-in: its button in its held load, the others gated, ×
    /// disabled once the load shows — and all of it cleared with nil.
    @Test func aRunningSignInHoldsItsButtonAndGatesTheRest() throws {
        let time = ManualLoadingClock()
        let (list, window) = Self.hostedList(time)
        defer { window.isHidden = true }

        list.setWorking(.provider(.apple))
        time.advance(AppButton.MorphMetrics.loadGrace)
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
        time.advance(AppButton.MorphMetrics.loadMinimum + 0.05)
        for method in Self.methods {
            let button = try #require(list.debugButton(for: method))
            #expect(button.phase == .content)
            #expect(button.isEnabled)
            #expect(button.acceptsTaps)
        }
        #expect(list.debugCloseItem.isEnabled)
    }

    /// ⚠️ LOCKED AT ONCE, GREY ONLY AFTER THE GRACE (#2270): the others and
    /// × refuse taps from the tap on, but turn grey only once the button's
    /// grace has passed with the call still running; the answer — the lock
    /// lifting, the caller going on — waits for the load's minimum.
    @Test func theOthersAreLockedAtOnceButGreyOnlyAfterTheGrace() throws {
        // Apple, not the passkey: `SignInMethod.all` lists no passkey row
        // (it is offered only when there is one to ask).
        let time = ManualLoadingClock()
        let (list, window) = Self.hostedList(time)
        defer { window.isHidden = true }
        let others = Self.methods.filter { $0 != .provider(.apple) }

        list.setWorking(.provider(.apple))
        #expect(list.locksOthers, "× takes a tap under a running sign-in")
        for method in others {
            let button = try #require(list.debugButton(for: method))
            #expect(!button.acceptsTaps, "\(method) takes a tap under a running sign-in")
            #expect(button.isEnabled, "\(method) greyed before the grace")
        }
        #expect(list.debugCloseItem.isEnabled, "× greyed before the grace")

        time.advance(AppButton.MorphMetrics.loadGrace - 0.02)
        #expect(others.allSatisfy { list.debugButton(for: $0)?.isEnabled == true }, "greyed before the grace")
        time.advance(0.04)
        for method in others {
            #expect(list.debugButton(for: method)?.isEnabled == false, "\(method) not grey past the grace")
        }
        #expect(!list.debugCloseItem.isEnabled, "× not grey past the grace")
        #expect(list.debugButton(for: .provider(.apple))?.isEnabled == true)

        var answered = false
        list.setWorking(nil) { answered = true }
        #expect(!answered, "the answer showed before the load's minimum")
        #expect(list.locksOthers)
        #expect(list.debugButton(for: .email)?.isEnabled == false)

        time.advance(AppButton.MorphMetrics.loadMinimum)
        #expect(answered)
        #expect(!list.locksOthers)
        #expect(others.allSatisfy { list.debugButton(for: $0)?.acceptsTaps == true })
        #expect(list.debugCloseItem.isEnabled)
    }

    /// A fast sign-in shows nothing but the press: nothing greys, and the
    /// caller goes on at once.
    @Test func aFastSignInGreysNothing() throws {
        let time = ManualLoadingClock()
        let (list, window) = Self.hostedList(time)
        defer { window.isHidden = true }
        list.setWorking(.provider(.apple))
        #expect(list.debugButton(for: .provider(.apple))?.phase == .loading, "guard: the sign-in is running")
        time.advance(AppButton.MorphMetrics.loadGrace / 2)
        var answered = false
        list.setWorking(nil) { answered = true }
        #expect(answered, "the caller waited for a load never drawn")
        #expect(time.pendingCount == 0, "the grace was left scheduled")
        time.advance(1)
        for method in Self.methods {
            let button = try #require(list.debugButton(for: method))
            #expect(button.isEnabled)
            #expect(button.acceptsTaps)
            #expect(!button.isLoadShown)
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
