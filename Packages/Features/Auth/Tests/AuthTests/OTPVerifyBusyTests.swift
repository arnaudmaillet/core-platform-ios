import DesignSystem
import Testing
import UIKit
@testable import Auth

/// The code's Verify at work (#1775): the word becomes the kit's loader,
/// under its identifier, once the full code goes — once.
@MainActor
struct OTPVerifyBusyTests {
    @Test func aFullCodeTurnsVerifyIntoTheLoaderAndGoesOnce() {
        let screen = OTPVerificationViewController(phoneDisplay: "+33 6 12 34 56 78")
        var sent: [String] = []
        screen.onVerify = { sent.append($0) }
        screen.loadViewIfNeeded()
        #expect(!screen.debugVerifyIsBusy)
        #expect(screen.ownTrailingBarItems.first?.identifier == OTPVerificationViewController.verifyID)

        screen.debugType("12345")
        #expect(!screen.debugVerifyIsBusy, "busy before the code was whole")
        screen.debugType("123456")
        #expect(screen.debugVerifyIsBusy, "Verify sat unchanged while the code went")
        #expect(screen.ownTrailingBarItems.first?.identifier == OTPVerificationViewController.verifyID)
        screen.debugType("123456")
        #expect(sent == ["123456"], "the code went twice")
    }
}
