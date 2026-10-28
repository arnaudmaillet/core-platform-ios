import DesignSystem
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

    /// ⚠️ STEPPED, NEVER TIMED: a wall-clock budget for bones due at 0.15 s
    /// ran out on a loaded CI runner (develop run 40610992777, 55 s).
    @Test func theSkeletonWaitsOutTheDelay() {
        let time = ManualLoadingClock()
        let controller = NotificationsViewController(
            viewModel: NotificationsViewModel(repository: Pending()), imagePipeline: nil
        )
        controller.skeletonClock = time.clock
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.loadViewIfNeeded()
        #expect(!controller.debugShowsSkeleton, "a bone at once, before the delay")
        time.advance(LoadingTiming.skeletonDelay / 2)
        #expect(!controller.debugShowsSkeleton, "a bone before the delay")
        time.advance(LoadingTiming.skeletonDelay)
        #expect(controller.debugShowsSkeleton)
    }
}
