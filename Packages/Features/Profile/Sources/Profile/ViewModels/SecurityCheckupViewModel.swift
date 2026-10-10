import DesignSystem
import Foundation

/// What the security checkup reads from the server: the account (email and
/// phone) and the logged-in devices.
///
/// ⚠️ **A FAILED READ USED TO DROP ITS LINES (#799).** Both were read with
/// `try?`, and `SecurityCheckup.items` leaves out what it doesn't know, so a
/// dropped connection removed "Verify your email" and "Review 3 logged-in
/// devices" — and the summary, counting only what was left, read "2 of 2
/// done": an all-clear on the one screen whose job is to say what isn't
/// protected. A failed read is now kept as `.failed`, drawn as a failed line
/// with retry and named in the summary.
@MainActor
final class SecurityCheckupViewModel {
    /// One server read, retried on its own.
    enum Part: Hashable, CaseIterable {
        case account, sessions
    }

    /// Nil when there is no account source: its lines are left out.
    private(set) var account: Loadable<AccountDetails>? {
        didSet { if account != oldValue { onChange?() } }
    }
    /// Nil when there is no sessions source: its line is left out.
    private(set) var sessionCount: Loadable<Int>? {
        didSet { if sessionCount != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    private let accountSource: (any AccountProviding)?
    private let sessionsSource: (any AccountSessionsManaging)?

    init(account: (any AccountProviding)?, sessions: (any AccountSessionsManaging)?) {
        accountSource = account
        sessionsSource = sessions
        self.account = account == nil ? nil : .loading
        sessionCount = sessions == nil ? nil : .loading
    }

    /// Reads both, side by side. Runs on every appearance (the viewer comes
    /// back from Security after logging a device out); a line already known
    /// keeps its value when a later read fails.
    func load() async {
        await withDiscardingTaskGroup { group in
            for part in Part.allCases {
                group.addTask { await self.reload(part) }
            }
        }
    }

    /// Reads one part — the failed line's retry. Returns false when the read
    /// failed, so the screen can say a retry failed again.
    @discardableResult
    func reload(_ part: Part) async -> Bool {
        switch part {
        case .account:
            guard let accountSource else { return true }
            let result = await settingsRead { try await accountSource.currentAccount() }
            account = account?.refreshed(by: result, failure: SecurityCheckup.failedAccountTitle)
            if case .success = result { return true }
        case .sessions:
            guard let sessionsSource else { return true }
            let result = await settingsRead { try await sessionsSource.activeSessions().count }
            sessionCount = sessionCount?.refreshed(by: result, failure: SecurityCheckup.failedSessionsTitle)
            if case .success = result { return true }
        }
        return false
    }
}
