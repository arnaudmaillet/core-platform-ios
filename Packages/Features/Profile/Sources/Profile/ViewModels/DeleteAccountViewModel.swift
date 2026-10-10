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
        /// Whether a deletion is already pending couldn't be read. The screen
        /// offers a retry, never the button: deleting on a state the app
        /// doesn't know is not a choice it hands the viewer.
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    /// Nil until read (or when nothing could be read). Published with the
    /// phase, never on its own: see `load`.
    private(set) var checklist: DeletionChecklist?
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
        // A retry shows the bones again while it reads.
        if case .failed = phase { phase = .loading }
        async let checklist = readChecklist()
        // A record that can't be read is a failure, not "no request yet": the
        // button would otherwise be offered on a guess.
        let status: AccountGdprStatus?
        do {
            status = try await lifecycle.gdprStatus()
        } catch {
            status = nil
        }
        // Both reads land in ONE change: the checklist first (it publishes
        // nothing by itself), then the phase. Publishing the phase and then
        // the checklist redrew the screen twice, the consequence lines
        // rewrapping under the viewer's eyes a moment after it settled.
        self.checklist = await checklist
        guard let status else {
            phase = .failed
            return
        }
        if let requestedAt = status.deletionRequestedAt {
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
