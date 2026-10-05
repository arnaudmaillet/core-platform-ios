import CoreContracts
import CoreModels
import Foundation

/// A kind of push the profile can switch (#392, backend #725).
public enum NotificationCategory: Equatable, Hashable, Sendable, CaseIterable {
    case likes, comments, mentions, newFollowers, followRequests, messages, followedPosts, placesNearby, wallet

    public var title: String {
        switch self {
        case .likes: "Likes"
        case .comments: "Comments"
        case .mentions: "Mentions"
        case .newFollowers: "New Followers"
        case .followRequests: "Follow Requests"
        case .messages: "Messages"
        case .followedPosts: "Posts From Accounts You Follow"
        case .placesNearby: "Places Nearby"
        case .wallet: "Wallet"
        }
    }

    init?(_ proto: Notification_V1_PushCategory) {
        switch proto {
        case .likes: self = .likes
        case .comments: self = .comments
        case .mentions: self = .mentions
        case .newFollowers: self = .newFollowers
        case .followRequests: self = .followRequests
        case .messages: self = .messages
        case .followedPosts: self = .followedPosts
        case .placesNearby: self = .placesNearby
        case .wallet: self = .wallet
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: Notification_V1_PushCategory {
        switch self {
        case .likes: .likes
        case .comments: .comments
        case .mentions: .mentions
        case .newFollowers: .newFollowers
        case .followRequests: .followRequests
        case .messages: .messages
        case .followedPosts: .followedPosts
        case .placesNearby: .placesNearby
        case .wallet: .wallet
        }
    }
}

/// Quiet hours, in minutes after midnight in the holder's time zone. They
/// may wrap midnight (22:00–07:00).
public struct QuietHours: Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int = 22 * 60, endMinute: Int = 7 * 60) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

/// The profile's push preferences. Every push is on by default; a 13–17
/// profile starts with quiet hours 22:00–07:00 (backend #725, #742).
public struct NotificationPreferences: Equatable, Sendable {
    /// The categories switched off; everything else pushes.
    public var mutedCategories: Set<NotificationCategory>
    /// A running pause; nil when none.
    public var pausedUntil: Date?
    /// Nil when quiet hours are off.
    public var quietHours: QuietHours?

    public init(mutedCategories: Set<NotificationCategory> = [], pausedUntil: Date? = nil, quietHours: QuietHours? = nil) {
        self.mutedCategories = mutedCategories
        self.pausedUntil = pausedUntil
        self.quietHours = quietHours
    }

    init(_ proto: Notification_V1_NotificationPreferences, now: Date = Date()) {
        let muted = proto.categories.filter { !$0.push }.compactMap { NotificationCategory($0.category) }
        let paused = proto.pausedUntilMs > 0 ? Date(timeIntervalSince1970: TimeInterval(proto.pausedUntilMs) / 1_000) : nil
        self.init(
            mutedCategories: Set(muted),
            pausedUntil: paused.flatMap { $0 > now ? $0 : nil },
            quietHours: proto.hasQuietHours && proto.quietHours.enabled
                ? QuietHours(startMinute: Int(proto.quietHours.startMinute), endMinute: Int(proto.quietHours.endMinute))
                : nil
        )
    }
}

/// One change to the preferences; the update is partial on the server.
public enum NotificationPreferencesChange: Equatable, Sendable {
    case push(NotificationCategory, Bool)
    /// Nil resumes.
    case pause(until: Date?)
    /// Nil turns quiet hours off.
    case quietHours(QuietHours?)
}

/// Settings → Notifications.
public protocol NotificationPreferencesManaging: Sendable {
    func notificationPreferences() async throws -> NotificationPreferences
    /// Applies one change; returns the preferences the server now holds.
    func updateNotificationPreferences(_ change: NotificationPreferencesChange) async throws -> NotificationPreferences
}

/// `notification.v1` preferences for the active profile.
public actor NotificationPreferencesRepository: NotificationPreferencesManaging {
    private let notificationClient: any Notification_V1_NotificationServiceClientInterface
    private let viewer: any ProfileViewerResolving

    public init(
        notificationClient: any Notification_V1_NotificationServiceClientInterface,
        viewer: any ProfileViewerResolving
    ) {
        self.notificationClient = notificationClient
        self.viewer = viewer
    }

    private func profileID() async throws -> String {
        guard let id = await viewer.viewerProfileID() else { throw ProfileError.notAuthenticated }
        return id.rawValue
    }

    public func notificationPreferences() async throws -> NotificationPreferences {
        var request = Notification_V1_GetNotificationPreferencesRequest()
        request.profileID = try await profileID()
        let response = await notificationClient.getNotificationPreferences(request: request, headers: [:])
        switch response.result {
        case .success(let body): return NotificationPreferences(body)
        case .failure(let error): throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func updateNotificationPreferences(_ change: NotificationPreferencesChange) async throws -> NotificationPreferences {
        var request = Notification_V1_UpdateNotificationPreferencesRequest()
        request.profileID = try await profileID()
        // The zone quiet hours are read in: this iPhone's.
        request.timezone = TimeZone.current.identifier
        switch change {
        case .push(let category, let isOn):
            var channels = Notification_V1_CategoryChannels()
            channels.category = category.proto
            channels.push = isOn
            request.categories = [channels]
        case .pause(let until):
            // At most 8 h on the server; 0 resumes.
            request.pausedUntilMs = until.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
        case .quietHours(let hours):
            var quiet = Notification_V1_QuietHours()
            quiet.enabled = hours != nil
            quiet.startMinute = Int32(hours?.startMinute ?? 22 * 60)
            quiet.endMinute = Int32(hours?.endMinute ?? 7 * 60)
            request.quietHours = quiet
        }
        let response = await notificationClient.updateNotificationPreferences(request: request, headers: [:])
        switch response.result {
        case .success(let body): return NotificationPreferences(body)
        case .failure(let error): throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
