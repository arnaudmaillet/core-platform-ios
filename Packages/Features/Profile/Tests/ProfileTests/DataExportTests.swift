import Foundation
import Testing
@testable import Profile

/// Settings → Account → Download Your Data (#387).
@MainActor
struct DataExportTests {
    private static let day: TimeInterval = 86_400
    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func phasesFollowTheRecord() {
        #expect(DataExportViewModel.phase(for: AccountGdprStatus()) == .available)
        #expect(DataExportViewModel.phase(for: AccountGdprStatus(exportRequestedAt: Self.t0)) == .preparing(requestedOn: Self.t0))
        let done = Self.t0.addingTimeInterval(Self.day)
        #expect(DataExportViewModel.phase(for: AccountGdprStatus(exportRequestedAt: Self.t0, exportCompletedAt: done)) == .ready(completedOn: done))
    }

    /// A completion older than the latest request belongs to the previous
    /// copy; the new one is still being prepared.
    @Test func aNewRequestAfterACompletedOneIsPreparing() {
        let oldDone = Self.t0
        let newRequest = Self.t0.addingTimeInterval(10 * Self.day)
        let status = AccountGdprStatus(exportRequestedAt: newRequest, exportCompletedAt: oldDone)
        #expect(DataExportViewModel.phase(for: status) == .preparing(requestedOn: newRequest))
    }

    @Test func requestingMovesToPreparing() async throws {
        let stub = StubExport()
        let model = DataExportViewModel(lifecycle: stub, now: { Self.t0 })
        await model.load()
        #expect(model.phase == .available)
        try await model.requestExport()
        #expect(await stub.exports == 1)
        #expect(model.phase == .preparing(requestedOn: Self.t0))
    }

    /// #799: an unreadable record used to offer "Request Download", as if
    /// nothing were on its way.
    @Test func anUnreadableRecordIsFailedNotAvailable() async {
        let model = DataExportViewModel(lifecycle: StubExport(failsRead: true))
        #expect(await model.load() == false)
        #expect(model.phase == .failed)
        #expect(DataExportViewController.statusText(for: .failed, email: nil).hasPrefix("Couldn't check"))
    }

    @Test func aRetryAfterAFailedReadLoadsTheRecord() async {
        let stub = StubExport(failsRead: true, status: AccountGdprStatus(exportRequestedAt: Self.t0))
        let model = DataExportViewModel(lifecycle: stub)
        await model.load()
        await stub.recover()
        #expect(await model.load())
        #expect(model.phase == .preparing(requestedOn: Self.t0))
    }

    @Test func aRetryThatFailsAgainStaysFailedAndReportsIt() async {
        let model = DataExportViewModel(lifecycle: StubExport(failsRead: true))
        await model.load()
        #expect(await model.load() == false)
        #expect(model.phase == .failed)
    }

    @Test func aFailedRefreshKeepsTheStateAlreadyShown() async {
        let stub = StubExport(status: AccountGdprStatus(exportRequestedAt: Self.t0))
        let model = DataExportViewModel(lifecycle: stub)
        await model.load()
        await stub.breakReads()
        #expect(await model.load() == false)
        #expect(model.phase == .preparing(requestedOn: Self.t0))
    }

    @Test func theStatusSaysWhereTheFileGoes() {
        let preparing = DataExportViewController.statusText(for: .preparing(requestedOn: Self.t0), email: "demo@example.com")
        #expect(preparing.contains("sent to demo@example.com"))
        #expect(preparing.contains("30 days"))
        let ready = DataExportViewController.statusText(for: .ready(completedOn: Self.t0), email: nil)
        #expect(ready.contains("sent to your email address"))
    }
}

private actor StubExport: AccountLifecycleManaging {
    private var failsRead: Bool
    private let status: AccountGdprStatus
    private(set) var exports = 0

    init(failsRead: Bool = false, status: AccountGdprStatus = AccountGdprStatus()) {
        self.failsRead = failsRead
        self.status = status
    }

    func recover() { failsRead = false }
    func breakReads() { failsRead = true }

    func requestDeletion() async throws {}
    func requestDataExport() async throws { exports += 1 }

    func gdprStatus() async throws -> AccountGdprStatus {
        if failsRead { throw AccountError.transport(message: "restricted") }
        return status
    }
}
