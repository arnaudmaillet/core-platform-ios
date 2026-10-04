import AuthInterface
import Connect
import CoreContracts
import CoreModels
import Foundation

public enum AccountError: Error, Equatable, Sendable {
    case notAuthenticated
    /// A step-up-gated RPC refused a token that wasn't re-proved recently
    /// (PERMISSION_DENIED "step_up_required"): ask for the password again.
    case stepUpRequired
    case transport(message: String)
}

/// Settings → Account → Deactivate Account (#385): the account's profiles are
/// hidden until the holder logs back in, which reactivates it. Step-up gated
/// on the server: call it right after `CredentialStepUp.stepUp`.
public protocol AccountDeactivating: Sendable {
    func deactivate() async throws
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
    /// Private: the holder's own view. Nil when none is on file (#394).
    public let dateOfBirth: BirthDate?
    public let ageBracket: AgeBracket

    public init(
        email: String, emailVerified: Bool, phone: String, phoneVerified: Bool, country: String,
        dateOfBirth: BirthDate? = nil, ageBracket: AgeBracket = .unknown
    ) {
        self.email = email
        self.emailVerified = emailVerified
        self.phone = phone
        self.phoneVerified = phoneVerified
        self.country = country
        self.dateOfBirth = dateOfBirth
        self.ageBracket = ageBracket
    }
}

/// What the Account Settings screen reads; implemented by `AccountRepository`.
public protocol AccountProviding: Sendable {
    /// The signed-in viewer's account, resolved from the auth session.
    func currentAccount() async throws -> AccountDetails
}

/// Where the account's GDPR requests stand, from `GetGdprRecord`.
public struct AccountGdprStatus: Equatable, Sendable {
    public var deletionRequestedAt: Date?
    public var exportRequestedAt: Date?
    public var exportCompletedAt: Date?

    public init(deletionRequestedAt: Date? = nil, exportRequestedAt: Date? = nil, exportCompletedAt: Date? = nil) {
        self.deletionRequestedAt = deletionRequestedAt
        self.exportRequestedAt = exportRequestedAt
        self.exportCompletedAt = exportCompletedAt
    }
}

/// The account's GDPR lifecycle (Settings → Account): erasure (#386) and the
/// data export (#387).
public protocol AccountLifecycleManaging: Sendable {
    /// Starts an Art. 17 erasure request for the signed-in account.
    func requestDeletion() async throws
    /// Starts an Art. 20 portability export for the signed-in account.
    func requestDataExport() async throws
    func gdprStatus() async throws -> AccountGdprStatus
}

/// How long a deletion request waits before it is permanent. A product
/// decision (2026-10-03, matching Instagram and TikTok); the backend's
/// `AnonymizeAccount` retention must match it.
public enum AccountDeletionPolicy {
    public static let gracePeriodDays = 30

    public static func permanentDate(requestedAt: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: gracePeriodDays, to: requestedAt) ?? requestedAt
    }
}

/// Reads the viewer's account from `account.v1` (`GetAccountById`), resolving
/// the account id from the auth session. Mirrors `ProfileRepository`'s shape.
public actor AccountRepository: AccountProviding, AccountLifecycleManaging, AccountDeactivating {
    let accountClient: any Account_V1_AccountServiceClientInterface
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
                country: view.countryOfResidence,
                dateOfBirth: BirthDate(iso: view.dateOfBirth),
                ageBracket: AgeBracket(view.ageBracket)
            )
        case .failure(let error):
            throw AccountError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func requestDeletion() async throws {
        var request = Account_V1_RequestGdprDeletionRequest()
        request.accountID = try await accountID()
        let response = await accountClient.requestGdprDeletion(request: request, headers: [:])
        if case .failure(let error) = response.result {
            throw Self.accountError(error)
        }
    }

    public func requestDataExport() async throws {
        var request = Account_V1_RequestDataExportRequest()
        request.accountID = try await accountID()
        let response = await accountClient.requestDataExport(request: request, headers: [:])
        if case .failure(let error) = response.result {
            throw AccountError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func gdprStatus() async throws -> AccountGdprStatus {
        var request = Account_V1_GetGdprRecordRequest()
        request.accountID = try await accountID()
        let response = await accountClient.getGdprRecord(request: request, headers: [:])
        switch response.result {
        case .success(let record):
            func date(_ seconds: Int64, _ nanos: Int32) -> Date {
                Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1e9)
            }
            return AccountGdprStatus(
                deletionRequestedAt: record.hasDeletionRequestedAt
                    ? date(record.deletionRequestedAt.seconds, record.deletionRequestedAt.nanos) : nil,
                exportRequestedAt: record.hasDataExportRequestedAt
                    ? date(record.dataExportRequestedAt.seconds, record.dataExportRequestedAt.nanos) : nil,
                exportCompletedAt: record.hasDataExportCompletedAt
                    ? date(record.dataExportCompletedAt.seconds, record.dataExportCompletedAt.nanos) : nil
            )
        case .failure(let error):
            throw AccountError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func deactivate() async throws {
        var request = Account_V1_DeactivateAccountRequest()
        request.accountID = try await accountID()
        let response = await accountClient.deactivateAccount(request: request, headers: [:])
        if case .failure(let error) = response.result {
            throw Self.accountError(error)
        }
    }

    /// A step-up-gated RPC's refusal is a prompt for the password, not a
    /// failure (PERMISSION_DENIED "step_up_required", #648).
    static func accountError(_ error: ConnectError) -> AccountError {
        if error.code == .permissionDenied, (error.message ?? "").contains("step_up") {
            return .stepUpRequired
        }
        return .transport(message: error.message ?? "code \(error.code)")
    }

    func accountID() async throws -> String {
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw AccountError.notAuthenticated
        }
        return accountID.rawValue
    }
}
