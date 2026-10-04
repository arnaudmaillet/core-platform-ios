import Connect
import CoreContracts
import Foundation
import SwiftProtobuf

/// Fake of `account.v1.AccountService` — what Settings → Account reads and
/// writes. The account is seeded from the same viewer as `MockAuthService`
/// (`acct-demo-0001`), with an email/phone and verification flags to exercise
/// the settings rows. The contract exposes no change-email / change-phone RPC,
/// so those stay read-only; the GDPR requests are recorded in memory and read
/// back through `GetGdprRecord`.
public final class MockAccountService: @unchecked Sendable {
    private let lock = NSLock()
    private var exportRequestedAt: Date?
    /// Consents as `UpdateConsents` left them, each with when it last changed.
    /// Data processing is given at sign-up.
    private var consents = (
        dataProcessing: (on: true, at: Date(timeIntervalSinceNow: -86_400 * 90)),
        marketing: (on: false, at: Date?.none),
        analytics: (on: true, at: Date(timeIntervalSinceNow: -86_400 * 90) as Date?)
    )
    /// None on file at launch, like an account created before it was
    /// collected; `-mock-birthdate YYYY-MM-DD` seeds one.
    private var dateOfBirth: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-mock-birthdate"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()
    /// How long the fake export takes to "prepare", so the screen can be seen
    /// in both states within one session.
    private static let exportPreparation: TimeInterval = 8

    private let lifecycle: MockAccountLifecycle

    public init(lifecycle: MockAccountLifecycle = MockAccountLifecycle()) {
        self.lifecycle = lifecycle
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/account.v1.AccountService/GetAccountById") { [self] (request: Account_V1_GetAccountByIdRequest) in
            getAccountByID(request)
        }
        bff.register(path: "/account.v1.AccountService/RequestGdprDeletion") { [self] (request: Account_V1_RequestGdprDeletionRequest, headers: Headers) in
            requestDeletion(request, headers: headers)
        }
        bff.register(path: "/account.v1.AccountService/RequestDataExport") { [self] (request: Account_V1_RequestDataExportRequest) in
            requestExport(request)
        }
        bff.register(path: "/account.v1.AccountService/GetGdprRecord") { [self] (request: Account_V1_GetGdprRecordRequest) in
            gdprRecord(request)
        }
        bff.register(path: "/account.v1.AccountService/DeactivateAccount") { [self] (request: Account_V1_DeactivateAccountRequest, headers: Headers) in
            deactivate(request, headers: headers)
        }
        bff.register(path: "/account.v1.AccountService/CancelGdprDeletion") { [self] (request: Account_V1_CancelGdprDeletionRequest) in
            cancelDeletion(request)
        }
        bff.register(path: "/account.v1.AccountService/UpdateConsents") { [self] (request: Account_V1_UpdateConsentsRequest) in
            updateConsents(request)
        }
        bff.register(path: "/account.v1.AccountService/SetDateOfBirth") { [self] (request: Account_V1_SetDateOfBirthRequest) in
            setDateOfBirth(request)
        }
    }

    /// Self-deactivation (#650): step-up gated, like on the fleet — a token
    /// not stepped up in the last few minutes is PERMISSION_DENIED
    /// "step_up_required". The next login resumes the account.
    private func deactivate(_ request: Account_V1_DeactivateAccountRequest, headers: Headers) -> Result<Account_V1_CommandResponse, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        if let refusal = stepUpRefusal(headers) { return .failure(refusal) }
        lifecycle.deactivate()
        var response = Account_V1_CommandResponse()
        response.success = true
        response.accountID = request.accountID
        return .success(response)
    }

    /// Step-up gated (#648), like `DeactivateAccount`.
    private func requestDeletion(_ request: Account_V1_RequestGdprDeletionRequest, headers: Headers) -> Result<Account_V1_CommandResponse, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        if let refusal = stepUpRefusal(headers) { return .failure(refusal) }
        // The backend also deactivates the account; the next login cancels.
        lifecycle.requestDeletion()
        var response = Account_V1_CommandResponse()
        response.success = true
        response.accountID = request.accountID
        return .success(response)
    }

    /// ACC-7003 when nothing is pending (the mock's grace period never ends).
    private func cancelDeletion(_ request: Account_V1_CancelGdprDeletionRequest) -> Result<Account_V1_CommandResponse, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        guard lifecycle.cancelDeletion() else {
            return .failure(ConnectError(code: .failedPrecondition, message: "ACC-7003: no deletion is pending"))
        }
        var response = Account_V1_CommandResponse()
        response.success = true
        response.accountID = request.accountID
        return .success(response)
    }

    /// Each field present changes that consent and stamps it; absent ones
    /// stay. Returns the updated record (backend #653).
    private func updateConsents(_ request: Account_V1_UpdateConsentsRequest) -> Result<Account_V1_GdprRecordView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        let now = Date()
        lock.withLock {
            if request.hasDataProcessing, request.dataProcessing != consents.dataProcessing.on {
                consents.dataProcessing = (request.dataProcessing, now)
            }
            if request.hasMarketing, request.marketing != consents.marketing.on {
                consents.marketing = (request.marketing, now)
            }
            if request.hasAnalytics, request.analytics != consents.analytics.on {
                consents.analytics = (request.analytics, now)
            }
        }
        var read = Account_V1_GetGdprRecordRequest()
        read.accountID = request.accountID
        return gdprRecord(read)
    }

    /// PERMISSION_DENIED "step_up_required" unless the bearer was stepped up
    /// in the last few minutes (`MockAccountLifecycle.stepUpWindow`).
    private func stepUpRefusal(_ headers: Headers) -> ConnectError? {
        let bearer = headers.first { $0.key.lowercased() == "authorization" }?.value.first ?? ""
        let token = bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst("Bearer ".count)) : bearer
        return lifecycle.isSteppedUp(accessToken: token)
            ? nil : ConnectError(code: .permissionDenied, message: "step_up_required: verify your password again")
    }

    private func requestExport(_ request: Account_V1_RequestDataExportRequest) -> Result<Account_V1_CommandResponse, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        lock.withLock { exportRequestedAt = Date() }
        var response = Account_V1_CommandResponse()
        response.success = true
        response.accountID = request.accountID
        return .success(response)
    }

    private func gdprRecord(_ request: Account_V1_GetGdprRecordRequest) -> Result<Account_V1_GdprRecordView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        var view = Account_V1_GdprRecordView()
        view.accountID = request.accountID
        if let deletionRequestedAt = lifecycle.deletionRequestedAt {
            view.deletionRequestedAt = .init(date: deletionRequestedAt)
            view.deletionScheduledAt = .init(date: deletionRequestedAt.addingTimeInterval(30 * 86_400))
        }
        lock.withLock {
            view.dataProcessingConsented = consents.dataProcessing.on
            view.dataProcessingConsentedAt = .init(date: consents.dataProcessing.at)
            view.marketingConsented = consents.marketing.on
            if let at = consents.marketing.at { view.marketingConsentedAt = .init(date: at) }
            view.analyticsConsented = consents.analytics.on
            if let at = consents.analytics.at { view.analyticsConsentedAt = .init(date: at) }
            if let exportRequestedAt {
                view.dataExportRequestedAt = .init(date: exportRequestedAt)
                let ready = exportRequestedAt.addingTimeInterval(Self.exportPreparation)
                if ready <= Date() { view.dataExportCompletedAt = .init(date: ready) }
            }
        }
        return .success(view)
    }

    private func getAccountByID(_ request: Account_V1_GetAccountByIdRequest) -> Result<Account_V1_AccountView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        return .success(viewerAccount)
    }

    /// The contract (backend #652): once, when none is on file; ISO 8601;
    /// under 13 is ACC-2004 and nothing is stored.
    private func setDateOfBirth(_ request: Account_V1_SetDateOfBirthRequest) -> Result<Account_V1_AccountView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        guard let age = Self.age(of: request.dateOfBirth) else {
            return .failure(ConnectError(code: .invalidArgument, message: "ACC-VAL-010: date_of_birth must be YYYY-MM-DD"))
        }
        let stored: Bool = lock.withLock {
            guard dateOfBirth == nil else { return false }
            if age >= 13 { dateOfBirth = request.dateOfBirth }
            return true
        }
        guard stored else {
            return .failure(ConnectError(code: .failedPrecondition, message: "ACC-2005: a date of birth is already on file"))
        }
        guard age >= 13 else {
            return .failure(ConnectError(code: .failedPrecondition, message: "ACC-2004: under the minimum age (13)"))
        }
        return .success(viewerAccount)
    }

    /// Whole years old today, or nil for a malformed date.
    private static func age(of iso: String) -> Int? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let now = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        var age = (now.year ?? 0) - parts[0]
        if (now.month ?? 0, now.day ?? 0) < (parts[1], parts[2]) { age -= 1 }
        return age
    }

    private var viewerAccount: Account_V1_AccountView {
        var view = Self.baseAccount
        if let dateOfBirth = lock.withLock({ dateOfBirth }), let age = Self.age(of: dateOfBirth) {
            view.dateOfBirth = dateOfBirth
            view.ageBracket = age >= 18 ? .adult : (age >= 16 ? .ageBracket1617 : .ageBracket1315)
        }
        return view
    }

    private static var baseAccount: Account_V1_AccountView {
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
