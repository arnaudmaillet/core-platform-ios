import DesignSystem
import Testing
import UIKit
@testable import Auth

// The form's bar (#2022): ? or the back on the left, × on the right, on
// every step; × behind the swipe's guard; a call disables, never hides.

private final class Step: UIViewController {}

private final class NoWayBackStep: UIViewController, AuthFormStep {
    var offersWayBack: Bool { false }
}

@MainActor
struct AuthFormBarTests {
    private func form(root: UIViewController = Step()) -> (ContentFittingNavigationController, UIWindow) {
        let form = ContentFittingNavigationController(rootViewController: root, isForm: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = form
        window.isHidden = false
        form.view.layoutIfNeeded()
        return (form, window)
    }

    private func closeItem(of step: UIViewController) -> UIBarButtonItem? {
        step.navigationItem.rightBarButtonItems?.first { $0.identifier == AuthFormBar.closeIdentifier }
    }

    /// `[?] … [×]` on the root; `[‹] … [×]` on a pushed step; `[?] … [×]` on
    /// a step with no way back, its back hidden.
    @Test func everyStepWearsCloseAndTheRootAndANoWayBackStepLeadWithHelp() {
        let root = Step()
        let (form, window) = form(root: root)
        defer { window.isHidden = true }
        #expect(root.navigationItem.leftBarButtonItem?.identifier == AuthFormBar.helpIdentifier)
        #expect(root.navigationItem.rightBarButtonItems?.first?.identifier == AuthFormBar.closeIdentifier)

        let next = Step()
        form.pushViewController(next, animated: false)
        #expect(next.navigationItem.leftBarButtonItem == nil, "a ? replaced the back chevron")
        #expect(!next.navigationItem.hidesBackButton)
        #expect(closeItem(of: next) != nil)

        let profile = NoWayBackStep()
        form.pushViewController(profile, animated: false)
        #expect(profile.navigationItem.hidesBackButton)
        #expect(profile.navigationItem.leftBarButtonItem?.identifier == AuthFormBar.helpIdentifier)
        #expect(closeItem(of: profile) != nil)
    }

    /// The rule, pure.
    @Test func theLeadingSlotRule() {
        #expect(AuthFormBar.leadsWithHelp(isRoot: true, offersWayBack: true))
        #expect(AuthFormBar.leadsWithHelp(isRoot: false, offersWayBack: false))
        #expect(!AuthFormBar.leadsWithHelp(isRoot: false, offersWayBack: true))
    }

    /// × before a code is sent closes the form at once; after, it asks the
    /// swipe's one confirmation.
    @Test func closeIsGuardedAsTheSwipeIs() throws {
        let root = Step()
        let (form, window) = form(root: root)
        defer { window.isHidden = true }
        var dismissed = 0
        form.onDismissed = { dismissed += 1 }

        form.protectsInput = { _ in false }
        form.closeForm()
        #expect(dismissed == 1, "× did not close the unprotected form")

        form.protectsInput = { _ in true }
        form.closeForm()
        #expect(dismissed == 1, "× closed a form holding a sent code without asking")
        let alert = try #require(root.presentedViewController as? UIAlertController)
        #expect(alert.title == ContentFittingNavigationController.leaveTitle)
    }

    /// A call locks × and the back (and the edge swipe) at once, greys
    /// them — never hides them — once its load shows (#2270); the end of the
    /// call enables them again.
    @Test func aCallDisablesCloseAndTheBackWithoutHidingThem() throws {
        let root = Step()
        let (form, window) = form(root: root)
        defer { window.isHidden = true }
        let next = Step()
        form.pushViewController(next, animated: false)
        var dismissed = 0
        form.onDismissed = { dismissed += 1 }

        form.setFormWorking(true)
        #expect(closeItem(of: next)?.isEnabled == true, "× greyed before the load shows")
        #expect(root.navigationItem.backBarButtonItem?.isEnabled == true, "the back greyed before the load shows")
        form.closeForm()
        #expect(dismissed == 0, "× closed the form under a call")
        form.setFormGreyed(true)
        #expect(closeItem(of: next)?.isEnabled == false)
        #expect(root.navigationItem.backBarButtonItem?.isEnabled == false, "the back is not disabled")
        #expect(!next.navigationItem.hidesBackButton, "the back was hidden")
        #expect(form.interactivePopGestureRecognizer?.isEnabled == false)
        #expect(root.navigationItem.leftBarButtonItem?.isEnabled != false, "? was disabled")

        // Whatever asks — the chevron, if UIKit lets its tap through — the
        // pop waits for the call.
        #expect(form.popViewController(animated: false) == nil, "a pop went through during a call")
        #expect(form.topViewController === next)

        form.setFormWorking(false)
        #expect(closeItem(of: next)?.isEnabled == true)
        #expect(root.navigationItem.backBarButtonItem?.isEnabled == true)
        #expect(form.interactivePopGestureRecognizer?.isEnabled == true)
    }

    /// A step's call (#2270): × and the back locked at once, grey only once
    /// the button's grace has passed with the call still running; the end
    /// — the step opening again, the caller going on — waits for the load's
    /// minimum.
    @Test func aStepsCallGreysTheBarOnlyOnceItsLoadShows() {
        let root = Step()
        let (form, window) = form(root: root)
        defer { window.isHidden = true }
        let step = SignUpStepViewController(emoji: "🔑", title: "T", subtitle: "S", buttonTitle: "Continue")
        form.pushViewController(step, animated: false)
        step.view.layoutIfNeeded()
        let time = ManualLoadingClock()
        step.primaryButton.loadClock = time.clock

        step.setWorking(true)
        #expect(form.isFormWorking)
        #expect(form.popViewController(animated: false) == nil, "a pop went through during a call")
        #expect(closeItem(of: step)?.isEnabled == true, "× greyed before the grace")
        #expect(root.navigationItem.backBarButtonItem?.isEnabled == true, "the back greyed before the grace")

        time.advance(AppButton.MorphMetrics.loadGrace)
        #expect(closeItem(of: step)?.isEnabled == false, "× not grey past the grace")
        #expect(root.navigationItem.backBarButtonItem?.isEnabled == false)

        var answered = false
        step.endWorking { answered = true }
        #expect(!answered, "the next step came before the load's minimum")
        #expect(form.isFormWorking)
        time.advance(AppButton.MorphMetrics.loadMinimum + 0.05)
        #expect(answered)
        #expect(!form.isFormWorking)
        #expect(closeItem(of: step)?.isEnabled == true)
        #expect(root.navigationItem.backBarButtonItem?.isEnabled == true)
    }

    /// The OTP seam: Cancel gave way to ×, Verify stands inboard of it, and
    /// the back leads.
    @Test func theOTPSeamJoinsTheRule() {
        let (form, window) = form()
        defer { window.isHidden = true }
        let otp = OTPVerificationViewController(phoneDisplay: "+33 6 12 34 56 78")
        form.pushViewController(otp, animated: false)
        let trailing = otp.navigationItem.rightBarButtonItems ?? []
        #expect(trailing.first?.identifier == AuthFormBar.closeIdentifier, "× is not outermost")
        #expect(trailing.count == 2, "Verify is not inboard of ×")
        #expect(otp.navigationItem.leftBarButtonItem == nil, "Cancel is still there")
    }

    /// The method list's bar is unchanged: its own identifiers.
    @Test func theListKeepsItsBar() {
        let list = MethodSelectionViewController()
        #expect(list.navigationItem.leftBarButtonItem?.identifier == MethodSelectionViewController.helpItemIdentifier)
        #expect(list.navigationItem.rightBarButtonItem?.identifier == MethodSelectionViewController.closeItemIdentifier)
    }
}
