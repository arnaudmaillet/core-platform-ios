import Connect
import CoreContracts
import Foundation

/// Fake of `account.v1.AccountService` — just enough for the Account Settings
/// screen to read the viewer's account. Only `GetAccountById` is registered
/// (the app's sole account read); the account is seeded from the same viewer as
/// `MockAuthService` (`acct-demo-0001`), with an email/phone and verification
/// flags to exercise the settings rows. Read-only: the contract exposes no
/// change-email / change-phone RPC, so there is nothing to mutate here.
public final class MockAccountService: @unchecked Sendable {
    public init() {}

    public func register(on bff: MockBFF) {
        bff.register(path: "/account.v1.AccountService/GetAccountById") { [self] (request: Account_V1_GetAccountByIdRequest) in
            getAccountByID(request)
        }
    }

    private func getAccountByID(_ request: Account_V1_GetAccountByIdRequest) -> Result<Account_V1_AccountView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        return .success(Self.viewerAccount)
    }

    private static var viewerAccount: Account_V1_AccountView {
        var view = Account_V1_AccountView()
        view.id = MockAuthService.accountID
        view.status = .active
        view.email = "demo@example.com"
        view.emailVerified = true
        view.phone = "+1 (555) 010-0142"
        view.phoneVerified = false
        view.countryOfResidence = "US"
        return view
    }
}
