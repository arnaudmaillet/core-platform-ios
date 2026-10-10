import DesignSystem
import Foundation

/// The account-info rows of Settings → Account: email, phone, date of birth.
///
/// ⚠️ **A FAILED READ USED TO DRAW AS AN EMPTY ACCOUNT (#799).** The screen
/// read the account with `try?`, so a dropped connection rendered Phone as
/// "Not set" and Date of Birth as "Add" — and "Add" pushed the one-time
/// date-of-birth editor for an account that may well have one on file. The
/// rows now wait for a value or show a failed row with retry.
@MainActor
final class AccountDetailsViewModel {
    typealias Phase = Loadable<AccountDetails>

    static let failureMessage = "Couldn't load your account details. Tap to try again."

    private(set) var phase: Phase = .loading {
        didSet { if phase != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    private let account: any AccountProviding

    init(account: any AccountProviding) {
        self.account = account
    }

    /// The details on screen, when there are some.
    var details: AccountDetails? { phase.content }

    /// Reads the account. A retry from the failed row goes back to the
    /// skeleton while it runs; a refresh over values already shown keeps
    /// them, failed or not. Returns false when the read failed, so the
    /// screen can say so for a retry or a refresh (the failed row says it
    /// for a first load).
    @discardableResult
    func load() async -> Bool {
        if phase.isFailed { phase = .loading }
        let account = account
        let result = await settingsRead { try await account.currentAccount() }
        phase = phase.refreshed(by: result, failure: Self.failureMessage)
        if case .success = result { return true }
        return false
    }
}
