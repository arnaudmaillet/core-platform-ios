import Foundation

/// State for Settings → Account → Download Your Data (#387, GDPR Art. 15/20).
@MainActor
final class DataExportViewModel {
    enum Phase: Equatable {
        case loading
        /// Nothing requested (or the record could not be read): offer it.
        case available
        /// Requested and still being prepared.
        case preparing(requestedOn: Date)
        /// The latest request is done.
        case ready(completedOn: Date)
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
        guard let status = try? await lifecycle.gdprStatus() else {
            phase = .available
            return
        }
        phase = Self.phase(for: status)
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
