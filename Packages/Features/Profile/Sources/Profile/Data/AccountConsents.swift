import CoreContracts
import Foundation

/// The consents on the account's GDPR record (Settings → Ads and Data →
/// Consents, #395, backend #653), each with when it last changed.
public struct AccountConsents: Equatable, Sendable {
    public struct Consent: Equatable, Sendable {
        public var isGiven: Bool
        /// When it was last given or withdrawn; nil if never recorded.
        public var changedAt: Date?

        public init(isGiven: Bool, changedAt: Date? = nil) {
            self.isGiven = isGiven
            self.changedAt = changedAt
        }
    }

    /// Processing the account's data to provide the service.
    public var dataProcessing: Consent
    /// Emails and offers about the app.
    public var marketing: Consent
    /// Usage statistics that help improve the app.
    public var analytics: Consent

    public init(dataProcessing: Consent, marketing: Consent, analytics: Consent) {
        self.dataProcessing = dataProcessing
        self.marketing = marketing
        self.analytics = analytics
    }

    init(_ record: Account_V1_GdprRecordView) {
        func date(_ seconds: Int64, _ nanos: Int32, present: Bool) -> Date? {
            present ? Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1e9) : nil
        }
        self.init(
            dataProcessing: Consent(
                isGiven: record.dataProcessingConsented,
                changedAt: date(record.dataProcessingConsentedAt.seconds, record.dataProcessingConsentedAt.nanos,
                                present: record.hasDataProcessingConsentedAt)
            ),
            marketing: Consent(
                isGiven: record.marketingConsented,
                changedAt: date(record.marketingConsentedAt.seconds, record.marketingConsentedAt.nanos,
                                present: record.hasMarketingConsentedAt)
            ),
            analytics: Consent(
                isGiven: record.analyticsConsented,
                changedAt: date(record.analyticsConsentedAt.seconds, record.analyticsConsentedAt.nanos,
                                present: record.hasAnalyticsConsentedAt)
            )
        )
    }
}

/// Reads and changes the consents. Withdrawing is as easy as giving
/// (GDPR Art. 7(3)): one switch, applied at once.
public protocol AccountConsentManaging: Sendable {
    func consents() async throws -> AccountConsents
    /// Changes only what is passed; returns the record as the server now has it.
    func updateConsents(marketing: Bool?, analytics: Bool?) async throws -> AccountConsents
}

/// Withdraws a pending erasure during its grace period (#402, backend #653).
/// Signing back in also cancels it; this is for a holder who is still signed
/// in on a device when the request was made elsewhere.
public protocol AccountDeletionCancelling: Sendable {
    func cancelDeletion() async throws
}

public enum DeletionCancelError: Error, Equatable {
    /// ACC-7003: no deletion is pending (already cancelled, or never asked).
    case nothingPending
    /// ACC-7004: the grace period is over.
    case tooLate
    case transport(message: String)
}

extension AccountRepository: AccountConsentManaging, AccountDeletionCancelling {
    public func consents() async throws -> AccountConsents {
        var request = Account_V1_GetGdprRecordRequest()
        request.accountID = try await accountID()
        let response = await accountClient.getGdprRecord(request: request, headers: [:])
        switch response.result {
        case .success(let record): return AccountConsents(record)
        case .failure(let error): throw AccountError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func updateConsents(marketing: Bool?, analytics: Bool?) async throws -> AccountConsents {
        var request = Account_V1_UpdateConsentsRequest()
        request.accountID = try await accountID()
        if let marketing { request.marketing = marketing }
        if let analytics { request.analytics = analytics }
        let response = await accountClient.updateConsents(request: request, headers: [:])
        switch response.result {
        case .success(let record): return AccountConsents(record)
        case .failure(let error): throw AccountError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func cancelDeletion() async throws {
        var request = Account_V1_CancelGdprDeletionRequest()
        request.accountID = try await accountID()
        let response = await accountClient.cancelGdprDeletion(request: request, headers: [:])
        if case .failure(let error) = response.result {
            let message = error.message ?? ""
            if message.contains("ACC-7003") { throw DeletionCancelError.nothingPending }
            if message.contains("ACC-7004") { throw DeletionCancelError.tooLate }
            throw DeletionCancelError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
