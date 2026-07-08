import AuthInterface
import CoreContracts
import CoreModels
import Foundation

public enum NotificationsError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    case transport(message: String)
}

/// One activity-feed row, hydrated with the sender's display name (the
/// notification.v1 view carries only ids). Aggregated notifications ("X and N
/// others") keep the primary sender plus a count.
public struct NotificationItem: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable {
        case reaction
        case comment
        case reply
        case mention
        case other
    }

    public let id: String
    public let action: Action
    public let senderID: ProfileID
    public let senderName: String
    /// Aggregated senders beyond the primary one ("and N others").
    public let otherSenderCount: Int
    /// Non-nil when the subject is a post — the tap target for `.post` routing.
    public let postSubjectID: PostID?
    public let isRead: Bool
    public let createdAt: Date

    public init(
        id: String,
        action: Action,
        senderID: ProfileID,
        senderName: String,
        otherSenderCount: Int,
        postSubjectID: PostID?,
        isRead: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.action = action
        self.senderID = senderID
        self.senderName = senderName
        self.otherSenderCount = otherSenderCount
        self.postSubjectID = postSubjectID
        self.isRead = isRead
        self.createdAt = createdAt
    }
}

/// What the notifications UI consumes; implemented by `NotificationsRepository`,
/// faked in view-model tests.
public protocol NotificationsProviding: Sendable {
    func loadNotifications(limit: Int32) async throws -> [NotificationItem]
    func markAllRead() async throws
    /// The viewer's unread notification count, for the tab badge.
    func unreadCount() async throws -> Int
}

/// Reads the viewer's activity from notification.v1, hydrating sender display
/// names via profile.v1 (the notification view carries only ids).
public actor NotificationsRepository: NotificationsProviding {
    private let notificationClient: any Notification_V1_NotificationServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let authSession: any AuthSessionProviding

    private var viewerProfileID: ProfileID?
    private var senderNameCache: [ProfileID: String] = [:]

    public init(
        notificationClient: any Notification_V1_NotificationServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        authSession: any AuthSessionProviding
    ) {
        self.notificationClient = notificationClient
        self.profileClient = profileClient
        self.authSession = authSession
    }

    // MARK: - NotificationsProviding

    public func loadNotifications(limit: Int32) async throws -> [NotificationItem] {
        let viewer = try await resolveViewerProfileID()

        var request = Notification_V1_ListNotificationsRequest()
        request.profileID = viewer.rawValue
        request.limit = limit
        let response = await notificationClient.listNotifications(request: request, headers: [:])
        let views: [Notification_V1_NotificationView]
        switch response.result {
        case .success(let body): views = body.notifications
        case .failure(let error): throw NotificationsError.transport(message: error.message ?? "code \(error.code)")
        }

        await hydrateSenderNames(for: views)
        return views.map(makeItem)
    }

    public func markAllRead() async throws {
        let viewer = try await resolveViewerProfileID()
        var request = Notification_V1_MarkAllReadRequest()
        request.profileID = viewer.rawValue
        let response = await notificationClient.markAllRead(request: request, headers: [:])
        if let error = response.error {
            throw NotificationsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func unreadCount() async throws -> Int {
        let viewer = try await resolveViewerProfileID()
        var request = Notification_V1_GetUnreadCountRequest()
        request.profileID = viewer.rawValue
        let response = await notificationClient.getUnreadCount(request: request, headers: [:])
        switch response.result {
        case .success(let body): return Int(body.unreadCount)
        case .failure(let error): throw NotificationsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    // MARK: - Hydration

    private func hydrateSenderNames(for views: [Notification_V1_NotificationView]) async {
        let missing = Set(views.map { ProfileID($0.senderProfileID) })
            .filter { senderNameCache[$0] == nil && !$0.rawValue.isEmpty }
        guard !missing.isEmpty else { return }

        let client = profileClient
        let fetched = await withTaskGroup(of: (ProfileID, String)?.self) { group in
            for id in missing {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id.rawValue
                    let response = await client.getProfileByID(request: request, headers: [:])
                    guard let view = response.message else { return nil }
                    return (id, view.displayName)
                }
            }
            return await group.reduce(into: [(ProfileID, String)]()) { partial, pair in
                if let pair { partial.append(pair) }
            }
        }
        for (id, name) in fetched {
            senderNameCache[id] = name
        }
    }

    private func makeItem(from view: Notification_V1_NotificationView) -> NotificationItem {
        let senderID = ProfileID(view.senderProfileID)
        let postSubjectID: PostID? = view.subjectKind == .post ? PostID(view.subjectID) : nil
        return NotificationItem(
            id: view.notificationID,
            action: Self.action(from: view.kind),
            senderID: senderID,
            senderName: senderNameCache[senderID] ?? "Someone",
            otherSenderCount: max(0, Int(view.senderCount) - 1),
            postSubjectID: postSubjectID,
            isRead: view.isRead,
            createdAt: Date(timeIntervalSince1970: TimeInterval(view.createdAtMs) / 1000)
        )
    }

    private static func action(from kind: Notification_V1_NotificationKind) -> NotificationItem.Action {
        switch kind {
        case .reaction: .reaction
        case .comment: .comment
        case .reply: .reply
        case .mention: .mention
        default: .other
        }
    }

    private func resolveViewerProfileID() async throws -> ProfileID {
        if let viewerProfileID {
            return viewerProfileID
        }
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw NotificationsError.notAuthenticated
        }
        var request = Profile_V1_ListProfilesByAccountRequest()
        request.accountID = accountID.rawValue
        let response = await profileClient.listProfilesByAccount(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            guard let profile = body.profiles.first else { throw NotificationsError.noProfileForAccount }
            let id = ProfileID(profile.profileID)
            viewerProfileID = id
            return id
        case .failure(let error):
            throw NotificationsError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
