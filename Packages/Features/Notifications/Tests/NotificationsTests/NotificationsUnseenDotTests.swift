import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Notifications

/// Two days of UNREAD notifications, taller than the screen, recording what
/// the list reads.
private actor UnreadProvider: NotificationsProviding {
    private(set) var markedReadIDs: [String] = []

    func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
        let now = Date()
        let today = (0..<10).map { item("t\($0)", at: now.addingTimeInterval(-Double($0) * 60)) }
        let yesterday = (0..<10).map { item("y\($0)", at: now.addingTimeInterval(-26 * 3600 - Double($0) * 60)) }
        return NotificationsPage(items: today + yesterday, nextPageToken: nil)
    }
    func markAllRead() async throws {}
    func markRead(_ items: [NotificationItem]) async throws { markedReadIDs += items.map(\.id) }
    func unreadCount() async throws -> Int { 0 }

    private func item(_ id: String, at date: Date) -> NotificationItem {
        NotificationItem(
            id: id, action: .reaction, senderID: ProfileID("p-\(id)"), senderName: "Ava",
            otherSenderCount: 0, postSubjectID: PostID("post-\(id)"), isRead: false, createdAt: date
        )
    }
}

/// The pink "not seen yet" dot (#1572): on every unread row, off once read,
/// and only the rows actually on screen are read.
@MainActor
@Suite(.serialized)
struct NotificationsUnseenDotTests {
    private func model(read: Bool) -> NotificationDisplayModel {
        NotificationDisplayModel(item: NotificationItem(
            id: "n", action: .reaction, senderID: ProfileID("p"), senderName: "Ava",
            otherSenderCount: 0, postSubjectID: PostID("post"), isRead: read, createdAt: Date()
        ))
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func anUnreadRowCarriesTheDot(style: UIUserInterfaceStyle) {
        let cell = NotificationCell(frame: CGRect(x: 0, y: 0, width: 402, height: 72))
        let traits = UITraitCollection(userInterfaceStyle: style)
        cell.traitOverrides.userInterfaceStyle = style
        cell.configure(with: model(read: false), imagePipeline: nil)
        #expect(cell.showsUnseenDot)
        #expect(cell.unseenDotResolvedColor == Palette.tint.resolvedColor(with: traits), "not the brand pink")
        #expect(cell.accessibilityLabel?.hasPrefix("Unread, ") == true)
        cell.configure(with: model(read: true), imagePipeline: nil)
        #expect(!cell.showsUnseenDot, "a read row keeps its dot")
        #expect(cell.accessibilityLabel?.hasPrefix("Unread") == false)
    }

    /// On screen, the rows in view are read; the rows below the fold are not.
    @Test func onlyTheRowsOnScreenAreRead() async throws {
        let provider = UnreadProvider()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let controller = NotificationsViewController(
            viewModel: NotificationsViewModel(repository: provider), imagePipeline: nil
        )
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        let list = try #require(controller.view.subviews.lazy.compactMap { $0 as? UICollectionView }.first)
        for _ in 0..<200 where await provider.markedReadIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        list.layoutIfNeeded()
        let read = Set(await provider.markedReadIDs)
        #expect(read.contains("t0"), "the first row, in view, was not read")
        #expect(!read.contains("y9"), "a row below the fold was read")
        #expect(Set(controller.seenRowIDs) == read, "what was read is not what is on screen")
    }
}
