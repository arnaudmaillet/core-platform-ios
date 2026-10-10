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
            phase = Self.phase(for: try await lifecycle.gdprStatus())
            return true
        } catch {
            if phase == .loading { phase = .failed }
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
