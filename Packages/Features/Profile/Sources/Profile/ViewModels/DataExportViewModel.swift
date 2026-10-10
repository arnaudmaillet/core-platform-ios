import CoreNetworking
import Foundation

/// State for Settings → Account → Download Your Data (#387, GDPR Art. 15/20).
@MainActor
final class DataExportViewModel {
    enum Phase: Equatable {
        case loading
        /// Nothing requested: offer it.
        case available
        /// Requested and still being prepared.
        case preparing(requestedOn: Date)
        /// The latest request is done.
        case ready(completedOn: Date)
        /// The record couldn't be read, and nothing older is on screen.
        ///
        /// ⚠️ **NOT `.available` (#799).** A failed read used to offer
        /// "Request Download", which says no copy is on its way when one may
        /// be: a second request on top of a pending one, or a viewer told
        /// nothing was prepared when the file is already in their inbox.
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    /// Why the last read failed, kept beside `.failed` so the row can say
    /// "You’re offline" when that is the cause (#794). Set before the phase,
    /// so the redraw `.failed` triggers already reads it.
    private(set) var failure: NetworkFailure?
    var onChange: (() -> Void)?

    private let lifecycle: any AccountLifecycleManaging
    private let now: () -> Date

    init(lifecycle: any AccountLifecycleManaging, now: @escaping () -> Date = Date.init) {
        self.lifecycle = lifecycle
        self.now = now
    }

    /// Reads where the export stands. A retry from the failed state shows
    /// "Checking…" while it runs; a refresh over a known state keeps it when
    /// the read fails. Returns false when the read failed, so the screen can
    /// say a retry failed again.
    @discardableResult
    func load() async -> Bool {
        if phase == .failed { phase = .loading }
        do {
            let status = try await lifecycle.gdprStatus()
            failure = nil
            phase = Self.phase(for: status)
            return true
        } catch {
            if phase == .loading {
                failure = NetworkFailure.of(error)
                phase = .failed
            }
            return false
        }
    }

    /// Where an export stands. A completion older than the latest request
    /// belongs to an earlier copy: the new one is still being prepared.
    static func phase(for status: AccountGdprStatus) -> Phase {
        switch (status.exportRequestedAt, status.exportCompletedAt) {
        case (let requested?, let completed?) where completed >= requested:
            .ready(completedOn: completed)
        case (let requested?, _):
            .preparing(requestedOn: requested)
        case (nil, let completed?):
            .ready(completedOn: completed)
        case (nil, nil):
            .available
        }
    }

    func requestExport() async throws {
        try await lifecycle.requestDataExport()
        phase = .preparing(requestedOn: now())
    }
}
