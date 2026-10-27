import CoreModels
import Foundation
import Testing
@testable import Notifications

/// A pull-to-refresh that fails while rows are on show (#1767): the rows stay,
/// and the host is told so it ends its pull and says why. The phase never
/// moved before, so the pull's indicator spun on with no word.
@MainActor
struct NotificationsRefreshFailureTests {
    private struct Offline: Error {}

    /// Answers the first load, then fails.
    private actor OnceThenFails: NotificationsProviding {
        private var loads = 0
        func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
            loads += 1
            guard loads == 1 else { throw Offline() }
            return NotificationsPage(items: [NotificationItem(
                id: "n1", action: .reaction, senderID: ProfileID("p"), senderName: "Ava",
                otherSenderCount: 0, postSubjectID: PostID("post-1"), isRead: true,
                createdAt: Date(timeIntervalSince1970: 100_000)
            )], nextPageToken: nil)
        }
        func markAllRead() async throws {}
        func unreadCount() async throws -> Int { 0 }
    }

    private func hasRows(_ phase: NotificationsViewModel.Phase?) -> Bool {
        if case .content = phase { return true }
        return false
    }

    @Test func aFailedRefreshOverRowsIsToldAndKeepsTheRows() async {
        let viewModel = NotificationsViewModel(repository: OnceThenFails())
        var last: NotificationsViewModel.Phase?
        var told: String?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.onRefreshFailed = { told = $0 }
        viewModel.viewDidLoad()
        for _ in 0..<300 where !hasRows(last) { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(hasRows(last), "the premise: rows on show")

        viewModel.refresh()
        for _ in 0..<300 where told == nil { try? await Task.sleep(for: .milliseconds(10)) }

        #expect(told != nil, "the refresh failed and nobody was told")
        #expect(hasRows(last), "the rows were dropped for an error")
    }
}
