import Foundation

/// State for Settings → Account → Delete Account (#386).
@MainActor
final class DeleteAccountViewModel {
    enum Phase: Equatable {
        case loading
        /// No request yet; deleting now would be permanent on this date.
        case ready(permanentOn: Date)
        /// Already requested: when, and when it becomes permanent.
        case requested(on: Date, permanentOn: Date)
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private let lifecycle: any AccountLifecycleManaging
    private let now: () -> Date

    init(lifecycle: any AccountLifecycleManaging, now: @escaping () -> Date = Date.init) {
        self.lifecycle = lifecycle
        self.now = now
    }

    func load() async {
        // A record we cannot read (the endpoint is restricted on some
        // deployments) is treated as "no request yet": the screen then offers
        // the button, and a duplicate request is harmless server-side.
        if let requestedAt = try? await lifecycle.gdprStatus().deletionRequestedAt {
            phase = .requested(on: requestedAt, permanentOn: AccountDeletionPolicy.permanentDate(requestedAt: requestedAt))
        } else {
            phase = .ready(permanentOn: AccountDeletionPolicy.permanentDate(requestedAt: now()))
        }
    }

    /// Requests deletion; returns the date it becomes permanent.
    func requestDeletion() async throws -> Date {
        try await lifecycle.requestDeletion()
        let requestedAt = now()
        let permanentOn = AccountDeletionPolicy.permanentDate(requestedAt: requestedAt)
        phase = .requested(on: requestedAt, permanentOn: permanentOn)
        return permanentOn
    }
}
