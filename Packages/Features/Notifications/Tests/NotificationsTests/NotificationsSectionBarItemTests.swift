import CoreModels
import Testing
import UIKit
@testable import Notifications

/// Two days of notifications: enough rows that the list scrolls past New.
private actor TwoDaysProvider: NotificationsProviding {
    func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
        let now = Date()
        let today = (0..<7).map { item("t\($0)", at: now.addingTimeInterval(-Double($0) * 60)) }
        let yesterday = (0..<7).map { item("y\($0)", at: now.addingTimeInterval(-26 * 3600 - Double($0) * 60)) }
        return NotificationsPage(items: today + yesterday, nextPageToken: nil)
    }
    func markAllRead() async throws {}
    func unreadCount() async throws -> Int { 0 }

    private func item(_ id: String, at date: Date) -> NotificationItem {
        NotificationItem(
            id: id, action: .reaction, senderID: ProfileID("p-\(id)"), senderName: "Ava",
            otherSenderCount: 0, postSubjectID: PostID("post-\(id)"), isRead: true, createdAt: date
        )
    }
}

/// The section the list is in, named in the bar's leading slot (#1573):
/// nothing at the top, New then Yesterday as the list scrolls.
@MainActor
@Suite(.serialized)
struct NotificationsSectionBarItemTests {
    @Test func theBarNamesTheSectionTheListIsIn() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let controller = NotificationsViewController(
            viewModel: NotificationsViewModel(repository: TwoDaysProvider()), imagePipeline: nil
        )
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        let list = try #require(controller.view.subviews.lazy.compactMap { $0 as? UICollectionView }.first)
        for _ in 0..<200 where list.numberOfSections < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try #require(list.numberOfSections == 2, "guard: two sections")
        list.layoutIfNeeded()
        #expect(controller.debugSectionItemTitle == nil, "the list at its top names a section")

        let top = list.adjustedContentInset.top
        list.contentOffset = CGPoint(x: 0, y: 120 - top)
        #expect(controller.debugSectionItemTitle == "New")
        let yesterday = try #require(list.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 1)
        ))
        list.contentOffset = CGPoint(x: 0, y: yesterday.frame.minY - top + 20)
        #expect(controller.debugSectionItemTitle == "Yesterday")
    }
}
