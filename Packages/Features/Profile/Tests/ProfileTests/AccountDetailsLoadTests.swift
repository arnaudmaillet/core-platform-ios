import DesignSystem
import Testing
@testable import Profile

/// Settings → Account's email, phone and date-of-birth rows (#799): a failed
/// read is a failed row with retry, never "Not set" or "Add".
@MainActor
struct AccountDetailsLoadTests {
    @Test func aFailedLoadIsFailedNotAnEmptyAccount() async {
        let model = AccountDetailsViewModel(account: SwitchableAccount(fails: true))
        #expect(await model.load() == false)
        #expect(model.phase == .failed(message: AccountDetailsViewModel.failureMessage))
        // Nothing for "Not set" / "Add" to be drawn from.
        #expect(model.details == nil)
    }

    @Test func aRetryAfterAFailedLoadShowsTheAccount() async {
        let account = SwitchableAccount(fails: true)
        let model = AccountDetailsViewModel(account: account)
        await model.load()
        await account.setFails(false)
        #expect(await model.load())
        #expect(model.phase == .content(SwitchableAccount.sample))
    }

    /// The skeleton comes back while a retry runs, so the failed row never
    /// sits there looking unanswered.
    @Test func aRetryGoesBackToLoadingWhileItRuns() async {
        let model = AccountDetailsViewModel(account: SwitchableAccount(fails: true))
        await model.load()
        var phases: [AccountDetailsViewModel.Phase] = []
        model.onChange = { [unowned model] in phases.append(model.phase) }
        await model.load()
        #expect(phases == [.loading, .failed(message: AccountDetailsViewModel.failureMessage)])
    }

    @Test func aRetryThatFailsAgainStaysFailedAndReportsIt() async {
        let account = SwitchableAccount(fails: true)
        let model = AccountDetailsViewModel(account: account)
        await model.load()
        #expect(await model.load() == false)
        #expect(model.phase.isFailed)
        #expect(await account.reads == 2)
    }

    /// After an edit the account is read again; a failure there keeps the
    /// values already on screen.
    @Test func aFailedRefreshKeepsTheValuesAlreadyShown() async {
        let account = SwitchableAccount()
        let model = AccountDetailsViewModel(account: account)
        await model.load()
        await account.setFails(true)
        #expect(await model.load() == false)
        #expect(model.details == SwitchableAccount.sample)
    }

    @Test func aRefreshShowsTheNewValues() async {
        let account = SwitchableAccount()
        let model = AccountDetailsViewModel(account: account)
        await model.load()
        let changed = AccountDetails(email: "new@b.c", emailVerified: false, phone: "", phoneVerified: false, country: "FR")
        await account.setDetails(changed)
        #expect(await model.load())
        #expect(model.details == changed)
    }

    @Test func aRefreshedValueOutlivesAFailureButAFirstFailureDoesNot() {
        struct Offline: Error {}
        let shown = Loadable<Int>.content(3)
        #expect(shown.refreshed(by: .failure(Offline()), failure: "x") == .content(3))
        #expect(Loadable<Int>.loading.refreshed(by: .failure(Offline()), failure: "x") == .failed(message: "x"))
        #expect(Loadable<Int>.failed(message: "x").refreshed(by: .success(4), failure: "x") == .content(4))
    }
}
