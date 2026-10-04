import Foundation
import Testing
@testable import Profile

/// Settings → Security and Login → Security Checkup (#418).
@MainActor
struct SecurityCheckupTests {
    private func account(emailVerified: Bool = true, phone: String = "+33600000000", phoneVerified: Bool = true) -> AccountDetails {
        AccountDetails(email: "a@b.c", emailVerified: emailVerified, phone: phone, phoneVerified: phoneVerified, country: "FR")
    }

    private func state(_ id: String, in items: [SecurityCheckupItem]) -> SecurityCheckupItem.State? {
        items.first { $0.id == id }?.state
    }

    @Test func aWellProtectedAccountIsAllDoneExceptWhatTheAppCantDo() {
        let items = SecurityCheckup.items(account: account(), sessionCount: 1, appLockOn: true, lockMethod: "Face ID")
        #expect(items.map(\.id) == ["email", "phone", "sessions", "appLock", "password", "twoFactor"])
        #expect(SecurityCheckup.summary(items) == "4 of 4 done")
        #expect(state("password", in: items) == .info)
        #expect(state("twoFactor", in: items) == .unavailable)
    }

    @Test func gapsAreRecommended() {
        let items = SecurityCheckup.items(
            account: account(emailVerified: false, phoneVerified: false), sessionCount: 3, appLockOn: false, lockMethod: "Face ID"
        )
        #expect(state("email", in: items) == .recommended)
        #expect(state("phone", in: items) == .recommended)
        #expect(state("sessions", in: items) == .recommended)
        #expect(state("appLock", in: items) == .recommended)
        #expect(items.first { $0.id == "sessions" }?.title == "Review 3 logged-in devices")
        #expect(SecurityCheckup.summary(items) == "0 of 4 done")
    }

    /// The app can't add a phone number, nor set up App Lock on a device with
    /// no passcode: those aren't counted against the viewer.
    @Test func whatTheViewerCantActOnIsNotCounted() {
        let items = SecurityCheckup.items(account: account(phone: ""), sessionCount: 1, appLockOn: false, lockMethod: nil)
        #expect(state("phone", in: items) == .unavailable)
        #expect(state("appLock", in: items) == .unavailable)
        #expect(SecurityCheckup.summary(items) == "2 of 2 done")
    }

    /// When the account or the sessions don't load, their lines are left out
    /// rather than guessed.
    @Test func unknownsAreLeftOut() {
        let items = SecurityCheckup.items(account: nil, sessionCount: nil, appLockOn: false, lockMethod: "Passcode")
        #expect(items.map(\.id) == ["appLock", "password", "twoFactor"])
        #expect(items.first?.title == "Turn on App Lock")
    }
}
