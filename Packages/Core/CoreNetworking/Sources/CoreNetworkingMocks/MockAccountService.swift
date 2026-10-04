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
    private var deletionRequestedAt: Date?
    private var exportRequestedAt: Date?
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
        lock.withLock {
            if deletionRequestedAt == nil { deletionRequestedAt = Date() }
        }
        var response = Account_V1_CommandResponse()
        response.success = true
        response.accountID = request.accountID
        return .success(response)
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
        view.dataProcessingConsented = true
        lock.withLock {
            if let deletionRequestedAt { view.deletionRequestedAt = .init(date: deletionRequestedAt) }
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
