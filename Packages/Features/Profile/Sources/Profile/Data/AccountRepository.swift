import AuthInterface
import Connect
import CoreContracts
import CoreModels
import Foundation

public enum AccountError: Error, Equatable, Sendable {
    case notAuthenticated
    case transport(message: String)
}

/// The signed-in viewer's account-level details, as the settings screen shows
/// them. Read-only in the app today: `account.v1` exposes no change-email /
/// change-phone RPC, so these are displayed and verified, never mutated here.
public struct AccountDetails: Equatable, Sendable {
    public let email: String
    public let emailVerified: Bool
    public let phone: String
    public let phoneVerified: Bool
    public let country: String

    public init(email: String, emailVerified: Bool, phone: String, phoneVerified: Bool, country: String) {
        self.email = email
        self.emailVerified = emailVerified
        self.phone = phone
        self.phoneVerified = phoneVerified
        self.country = country
    }
}

/// What the Account Settings screen reads; implemented by `AccountRepository`.
public protocol AccountProviding: Sendable {
    /// The signed-in viewer's account, resolved from the auth session.
    func currentAccount() async throws -> AccountDetails
}

/// Reads the viewer's account from `account.v1` (`GetAccountById`), resolving
/// the account id from the auth session. Mirrors `ProfileRepository`'s shape.
public actor AccountRepository: AccountProviding {
    private let accountClient: any Account_V1_AccountServiceClientInterface
    private let authSession: any AuthSessionProviding

    public init(
        accountClient: any Account_V1_AccountServiceClientInterface,
        authSession: any AuthSessionProviding
    ) {
        self.accountClient = accountClient
        self.authSession = authSession
    }

    public func currentAccount() async throws -> AccountDetails {
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw AccountError.notAuthenticated
        }

        var request = Account_V1_GetAccountByIdRequest()
        request.accountID = accountID.rawValue
        let response = await accountClient.getAccountByID(request: request, headers: [:])
        switch response.result {
        case .success(let view):
            return AccountDetails(
                email: view.email,
                emailVerified: view.emailVerified,
                phone: view.phone,
                phoneVerified: view.phoneVerified,
                country: view.countryOfResidence
            )
        case .failure(let error):
            throw AccountError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
