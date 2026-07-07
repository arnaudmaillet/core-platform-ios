import Connect
import CoreContracts
import Foundation

/// Fake of notification.v1.NotificationService over the shared dataset. Emits a
/// few deterministic activity rows (the fleet seeds none), and accepts
/// MarkAllRead. Senders are dataset authors, so profile hydration resolves.
public final class MockNotificationService: @unchecked Sendable {
    private let dataset: MockSocialDataset

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/notification.v1.NotificationService/ListNotifications") { [self] (request: Notification_V1_ListNotificationsRequest) in
            list(request)
        }
        bff.register(path: "/notification.v1.NotificationService/MarkAllRead") { (_: Notification_V1_MarkAllReadRequest) in
            var response = Notification_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/notification.v1.NotificationService/GetUnreadCount") { [self] (_: Notification_V1_GetUnreadCountRequest) in
            var response = Notification_V1_GetUnreadCountResponse()
            response.unreadCount = 2
            return .success(response)
        }
    }

    private func list(_ request: Notification_V1_ListNotificationsRequest) -> Result<Notification_V1_ListNotificationsResponse, ConnectError> {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let minute: Int64 = 60_000
        let authors = dataset.authors
        let posts = dataset.posts

        // (senderIndex, kind, subjectPostIndex, senderCount, minutesAgo, isRead)
        let specs: [(Int, Notification_V1_NotificationKind, Int, Int32, Int64, Bool)] = [
            (0, .reaction, 0, 1, 3, false),
            (1, .comment, 1, 1, 42, false),
            (2, .reaction, 2, 4, 60 * 5, true),
            (3, .mention, 3, 1, 60 * 26, true)
        ]

        let notifications: [Notification_V1_NotificationView] = specs.enumerated().compactMap { offset, spec in
            let (senderIndex, kind, postIndex, senderCount, minutesAgo, isRead) = spec
            guard authors.indices.contains(senderIndex), posts.indices.contains(postIndex) else { return nil }
            var view = Notification_V1_NotificationView()
            view.notificationID = "notif-\(offset)"
            view.targetProfileID = request.profileID
            view.senderProfileID = authors[senderIndex].profileID
            view.senderCount = senderCount
            view.kind = kind
            view.subjectKind = .post
            view.subjectID = posts[postIndex].postID
            view.createdAtMs = nowMs - minutesAgo * minute
            view.isRead = isRead
            return view
        }

        var response = Notification_V1_ListNotificationsResponse()
        response.notifications = notifications
        response.readHorizonMs = nowMs
        return .success(response)
    }
}
