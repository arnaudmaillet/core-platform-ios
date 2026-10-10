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
        let items = SecurityCheckup.items(account: .content(account()), sessionCount: .content(1), appLockOn: true, lockMethod: "Face ID")
        #expect(items.map(\.id) == ["email", "phone", "sessions", "appLock", "password", "twoFactor"])
        #expect(SecurityCheckup.summary(items) == "4 of 4 done")
        #expect(state("password", in: items) == .info)
        #expect(state("twoFactor", in: items) == .unavailable)
    }

    @Test func gapsAreRecommended() {
        let items = SecurityCheckup.items(
            account: .content(account(emailVerified: false, phoneVerified: false)), sessionCount: .content(3), appLockOn: false, lockMethod: "Face ID"
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
        let items = SecurityCheckup.items(account: .content(account(phone: "")), sessionCount: .content(1), appLockOn: false, lockMethod: nil)
        #expect(state("phone", in: items) == .unavailable)
        #expect(state("appLock", in: items) == .unavailable)
        #expect(SecurityCheckup.summary(items) == "2 of 2 done")
    }

    /// A source the screen doesn't have, or a read still running, leaves its
    /// lines out: there is nothing to say about it yet.
    @Test func absentSourcesAndRunningReadsAreLeftOut() {
        let absent = SecurityCheckup.items(account: nil, sessionCount: nil, appLockOn: false, lockMethod: "Passcode")
        #expect(absent.map(\.id) == ["appLock", "password", "twoFactor"])
        #expect(absent.first?.title == "Turn on App Lock")
        let running = SecurityCheckup.items(account: .loading, sessionCount: .loading, appLockOn: false, lockMethod: "Passcode")
        #expect(running.map(\.id) == ["appLock", "password", "twoFactor"])
    }

    /// #799: a failed read keeps its line, as a failed line, and the summary
    /// names it — it used to vanish and leave "1 of 1 done".
    @Test func aFailedReadIsAFailedLineAndTheSummaryNeverReadsAllClear() {
        let items = SecurityCheckup.items(
            account: .failed(message: "x"), sessionCount: .failed(message: "x"), appLockOn: true, lockMethod: "Face ID"
        )
        #expect(items.map(\.id) == ["account", "sessions", "appLock", "password", "twoFactor"])
        #expect(state("account", in: items) == .failed)
        #expect(state("sessions", in: items) == .failed)
        #expect(items.first?.title == SecurityCheckup.failedAccountTitle)
        #expect(SecurityCheckup.summary(items) == "1 of 1 done, 2 couldn't be checked")
    }

    @Test func aFailedLoadBecomesFailedLinesNotAnAllClear() async {
        let model = SecurityCheckupViewModel(
            account: SwitchableAccount(fails: true), sessions: SwitchableSessions(count: 3, fails: true)
        )
        await model.load()
        #expect(model.account?.isFailed == true)
        #expect(model.sessionCount?.isFailed == true)
    }

    @Test func retryingOnePartLoadsOnlyThatPart() async {
        let account = SwitchableAccount(fails: true)
        let sessions = SwitchableSessions(count: 3, fails: true)
        let model = SecurityCheckupViewModel(account: account, sessions: sessions)
        await model.load()
        await account.setFails(false)
        #expect(await model.reload(.account))
        #expect(model.account == .content(SwitchableAccount.sample))
        #expect(model.sessionCount?.isFailed == true)
        await sessions.setFails(false)
        #expect(await model.reload(.sessions))
        #expect(model.sessionCount == .content(3))
    }

    @Test func aRetryThatFailsAgainStaysFailedAndReportsIt() async {
        let model = SecurityCheckupViewModel(account: SwitchableAccount(fails: true), sessions: nil)
        await model.load()
        #expect(await model.reload(.account) == false)
        #expect(model.account?.isFailed == true)
        #expect(model.sessionCount == nil)
    }

    /// A double tap on a failed line (or an appearance mid-retry): one read,
    /// so offline one toast.
    @Test(.timeLimit(.minutes(10))) func aSecondRetryWhileOneIsInFlightSendsNoSecondRead() async {
        let gate = ReadGate()
        let account = SwitchableAccount(fails: true, gate: gate)
        let model = SecurityCheckupViewModel(account: account, sessions: nil)
        let first = Task { await model.reload(.account) }
        await gate.waitUntilEntered()
        #expect(model.reading == [.account])
        #expect(await model.reload(.account), "the duplicate has nothing to report")
        await gate.release()
        #expect(await first.value == false)
        #expect(await account.reads == 1)
        #expect(model.reading.isEmpty)
    }

    /// The checkup reloads on every appearance; a line it already knows
    /// keeps its value when a later read fails.
    @Test func aFailedRefreshKeepsTheLinesAlreadyShown() async {
        let account = SwitchableAccount()
        let sessions = SwitchableSessions(count: 2)
        let model = SecurityCheckupViewModel(account: account, sessions: sessions)
        await model.load()
        await account.setFails(true)
        await sessions.setFails(true)
        await model.load()
        #expect(model.account == .content(SwitchableAccount.sample))
        #expect(model.sessionCount == .content(2))
    }
}
