import Foundation

/// What this account would lose, named before the irreversible step (#402):
/// its profiles by handle, and what is left in the wallet. Nil fields were
/// unreadable; the screen then falls back to the general wording.
struct DeletionChecklist: Equatable, Sendable {
    /// Every profile on the account, by handle (without `@`).
    var profileHandles: [String]?
    var points: Int?
    var gems: Int?
}

/// State for Settings → Account → Delete Account (#386, #402).
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
    /// Nil until read (or when nothing could be read).
    private(set) var checklist: DeletionChecklist? {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private let lifecycle: any AccountLifecycleManaging
    private let readChecklist: @Sendable () async -> DeletionChecklist?
    private let now: () -> Date

    init(
        lifecycle: any AccountLifecycleManaging,
        checklist: @escaping @Sendable () async -> DeletionChecklist? = { nil },
        now: @escaping () -> Date = Date.init
    ) {
        self.lifecycle = lifecycle
        self.readChecklist = checklist
        self.now = now
    }

    func load() async {
        async let checklist = readChecklist()
        // A record we cannot read (the endpoint is restricted on some
        // deployments) is treated as "no request yet": the screen then offers
        // the button, and a duplicate request is harmless server-side.
        if let requestedAt = try? await lifecycle.gdprStatus().deletionRequestedAt {
            phase = .requested(on: requestedAt, permanentOn: AccountDeletionPolicy.permanentDate(requestedAt: requestedAt))
        } else {
            phase = .ready(permanentOn: AccountDeletionPolicy.permanentDate(requestedAt: now()))
        }
        self.checklist = await checklist
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
