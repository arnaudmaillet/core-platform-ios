import Foundation
import Testing
import UIKit
@testable import Notifications

/// The notifications' skeleton on the kit's timing (#1770): nothing for the
/// delay — a list that answers at once never shows a bone — then the bones.
@MainActor
struct NotificationsSkeletonGateTests {
    /// A first page that never answers in a test's time.
    private struct Pending: NotificationsProviding {
        func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
            try await Task.sleep(for: .seconds(60))
            return NotificationsPage(items: [], nextPageToken: nil)
        }
        func markAllRead() async throws {}
        func unreadCount() async throws -> Int { 0 }
    }

    @Test func theSkeletonWaitsOutTheDelay() async {
        let controller = NotificationsViewController(
            viewModel: NotificationsViewModel(repository: Pending()), imagePipeline: nil
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.loadViewIfNeeded()
        #expect(!controller.debugShowsSkeleton, "a bone at once, before the delay")
        for _ in 0..<200 where !controller.debugShowsSkeleton { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.debugShowsSkeleton)
    }
}
