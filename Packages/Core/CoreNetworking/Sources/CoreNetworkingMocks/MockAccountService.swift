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

    public init() {}

    public func register(on bff: MockBFF) {
        bff.register(path: "/account.v1.AccountService/GetAccountById") { [self] (request: Account_V1_GetAccountByIdRequest) in
            getAccountByID(request)
        }
        bff.register(path: "/account.v1.AccountService/RequestGdprDeletion") { [self] (request: Account_V1_RequestGdprDeletionRequest) in
            requestDeletion(request)
        }
        bff.register(path: "/account.v1.AccountService/GetGdprRecord") { [self] (request: Account_V1_GetGdprRecordRequest) in
            gdprRecord(request)
        }
    }

    private func requestDeletion(_ request: Account_V1_RequestGdprDeletionRequest) -> Result<Account_V1_CommandResponse, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .notFound, message: "account \(request.accountID) not found"))
        }
        lock.withLock {
            if deletionRequestedAt == nil { deletionRequestedAt = Date() }
        }
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
