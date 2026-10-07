import Connect
import CoreContracts
import Foundation

/// Fake of notification.v1.NotificationService over the shared dataset. Emits
/// deterministic activity on the VIEWER's own posts (the fleet seeds none), and
/// honours MarkAllRead: once called, every row reads as read and the unread
/// count is zero — so the drawer's "New" section empties the way it would
/// against a real server. Senders are dataset authors, so profile hydration
/// resolves, and their pictures are the dataset's real photographs (or none —
/// every fourth author has no picture, which exercises the initials).
public final class MockNotificationService: @unchecked Sendable {
    private let dataset: MockSocialDataset
    /// Cleared by MarkAllRead so the badge demo is realistic.
    private let readState = ReadState()

    /// One fixture: who, what, on which of the viewer's posts, how many people
    /// the row stands for, which of them the server names, how long ago, and
    /// whether it was already read.
    private struct Spec {
        let sender: Int
        let kind: Notification_V1_NotificationKind
        /// Index into the viewer's own posts (`post-me-NN`), wrapped.
        let post: Int
        let senderCount: Int32
        /// Other named senders (author indices), for the stacked avatars.
        let samples: [Int]
        let minutesAgo: Int64
        let isRead: Bool
    }

    /// Ten unread rows once the client folds rows 0 and 5 (the same like on
    /// the same post, delivered separately) — six show, "Show 4 more" holds
    /// the rest — then six read ones, then an older read tail
    /// (`olderSpecs`). The viewer's posts cycle video, photo,
    /// text (`post-me-00` video, `-01` photo, `-02` text…), so thumbnails and
    /// excerpts both appear. Authors 3, 7, 11 and 15 have no picture.
    private static let specs: [Spec] = recentSpecs + olderSpecs

    /// Weeks-old read activity, one a day: enough rows that the drawer needs
    /// more than one page to reach the oldest (#608). Kinds rotate so
    /// neighbours rarely fold into one row.
    private static let olderSpecs: [Spec] = (0..<30).map { index in
        let kinds: [Notification_V1_NotificationKind] = [.reaction, .comment, .mention, .reply]
        return Spec(
            sender: (index * 7) % 20, kind: kinds[index % kinds.count], post: index,
            senderCount: 1, samples: [], minutesAgo: 60 * 24 * Int64(10 + index), isRead: true
        )
    }

    private static let recentSpecs: [Spec] = [
        Spec(sender: 0, kind: .reaction, post: 0, senderCount: 1, samples: [], minutesAgo: 2, isRead: false),
        Spec(sender: 5, kind: .comment, post: 1, senderCount: 1, samples: [], minutesAgo: 9, isRead: false),
        Spec(sender: 2, kind: .reaction, post: 2, senderCount: 5, samples: [6, 9], minutesAgo: 25, isRead: false),
        Spec(sender: 7, kind: .mention, post: 4, senderCount: 1, samples: [], minutesAgo: 48, isRead: false),
        Spec(sender: 1, kind: .reply, post: 5, senderCount: 1, samples: [], minutesAgo: 70, isRead: false),
        Spec(sender: 8, kind: .reaction, post: 0, senderCount: 1, samples: [], minutesAgo: 95, isRead: false),
        Spec(sender: 10, kind: .comment, post: 3, senderCount: 1, samples: [], minutesAgo: 60 * 3, isRead: false),
        Spec(sender: 4, kind: .reaction, post: 6, senderCount: 3, samples: [12], minutesAgo: 60 * 5, isRead: false),
        Spec(sender: 11, kind: .mention, post: 7, senderCount: 1, samples: [], minutesAgo: 60 * 8, isRead: false),
        Spec(sender: 13, kind: .comment, post: 2, senderCount: 1, samples: [], minutesAgo: 60 * 11, isRead: false),
        Spec(sender: 14, kind: .reaction, post: 8, senderCount: 1, samples: [], minutesAgo: 60 * 14, isRead: false),
        Spec(sender: 3, kind: .reaction, post: 1, senderCount: 2, samples: [16], minutesAgo: 60 * 26, isRead: true),
        Spec(sender: 6, kind: .comment, post: 4, senderCount: 1, samples: [], minutesAgo: 60 * 29, isRead: true),
        Spec(sender: 9, kind: .mention, post: 5, senderCount: 1, samples: [], minutesAgo: 60 * 50, isRead: true),
        Spec(sender: 12, kind: .reaction, post: 3, senderCount: 7, samples: [17, 18], minutesAgo: 60 * 75, isRead: true),
        Spec(sender: 15, kind: .reply, post: 7, senderCount: 1, samples: [], minutesAgo: 60 * 24 * 5, isRead: true),
        Spec(sender: 16, kind: .reaction, post: 6, senderCount: 1, samples: [], minutesAgo: 60 * 24 * 9, isRead: true)
    ]

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    /// Push preferences by profile (backend #725): every push on, every
    /// email off, no pause, no quiet hours until set.
    private let preferencesLock = NSLock()
    private var preferences: [String: Notification_V1_NotificationPreferences] = [:]

    private static func defaultPreferences() -> Notification_V1_NotificationPreferences {
        var preferences = Notification_V1_NotificationPreferences()
        preferences.categories = Notification_V1_PushCategory.allCases
            .filter { if case .UNRECOGNIZED = $0 { false } else { $0 != .unspecified } }
            .map { category in
                var channels = Notification_V1_CategoryChannels()
                channels.category = category
                channels.push = true
                channels.email = false
                return channels
            }
        return preferences
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/notification.v1.NotificationService/ListNotifications") { [self] (request: Notification_V1_ListNotificationsRequest) in
            list(request)
        }
        bff.register(path: "/notification.v1.NotificationService/MarkAllRead") { [self] (_: Notification_V1_MarkAllReadRequest) in
            readState.markAllRead()
            var response = Notification_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/notification.v1.NotificationService/GetNotificationPreferences") { [self] (request: Notification_V1_GetNotificationPreferencesRequest) in
            .success(preferencesLock.withLock { preferences[request.profileID] } ?? Self.defaultPreferences())
        }
        bff.register(path: "/notification.v1.NotificationService/UpdateNotificationPreferences") { [self] (request: Notification_V1_UpdateNotificationPreferencesRequest) -> Result<Notification_V1_NotificationPreferences, ConnectError> in
            let nowMS = Int64(Date().timeIntervalSince1970 * 1_000)
            if request.hasPausedUntilMs, request.pausedUntilMs > nowMS + 8 * 3_600_000 + 60_000 {
                return .failure(ConnectError(code: .invalidArgument, message: "NTF-9001: a pause lasts at most 8 hours"))
            }
            // Partial: only what's sent changes.
            let updated = preferencesLock.withLock {
                var current = preferences[request.profileID] ?? Self.defaultPreferences()
                for change in request.categories {
                    if let index = current.categories.firstIndex(where: { $0.category == change.category }) {
                        current.categories[index] = change
                    } else {
                        current.categories.append(change)
                    }
                }
                if request.hasPausedUntilMs { current.pausedUntilMs = request.pausedUntilMs }
                if request.hasQuietHours { current.quietHours = request.quietHours }
                if !request.timezone.isEmpty { current.timezone = request.timezone }
                preferences[request.profileID] = current
                return current
            }
            return .success(updated)
        }
        bff.register(path: "/notification.v1.NotificationService/GetUnreadCount") { [self] (_: Notification_V1_GetUnreadCountRequest) in
            var response = Notification_V1_GetUnreadCountResponse()
            response.unreadCount = readState.allRead ? 0 : Int64(Self.specs.filter { !$0.isRead }.count)
            return .success(response)
        }
    }

    private final class ReadState: @unchecked Sendable {
        private let lock = NSLock()
        private var cleared = false
        var allRead: Bool { lock.withLock { cleared } }
        func markAllRead() { lock.withLock { cleared = true } }
    }

    private func list(_ request: Notification_V1_ListNotificationsRequest) -> Result<Notification_V1_ListNotificationsResponse, ConnectError> {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let minute: Int64 = 60_000
        let authors = dataset.authors
        let viewerPosts = dataset.posts
            .filter { $0.authorProfileID == MockSocialDataset.viewerProfileID }
            .sorted { $0.postID < $1.postID }
        guard !authors.isEmpty, !viewerPosts.isEmpty else {
            return .success(Notification_V1_ListNotificationsResponse())
        }
        let allRead = readState.allRead

        let notifications: [Notification_V1_NotificationView] = Self.specs.enumerated().map { offset, spec in
            var view = Notification_V1_NotificationView()
            view.notificationID = "notif-\(offset)"
            view.targetProfileID = request.profileID
            view.senderProfileID = authors[spec.sender % authors.count].profileID
            // The contract's samples lead with the primary sender.
            view.sampleSenderIds = spec.senderCount > 1
                ? [view.senderProfileID] + spec.samples.map { authors[$0 % authors.count].profileID }
                : []
            view.senderCount = spec.senderCount
            view.kind = spec.kind
            view.subjectKind = .post
            view.subjectID = viewerPosts[spec.post % viewerPosts.count].postID
            view.createdAtMs = nowMs - spec.minutesAgo * minute
            view.isRead = spec.isRead || allRead
            return view
        }

        // Paged (#608): at most `limit` from where `page_token` left off, with
        // a token while there are more. The token is an offset here — opaque
        // to the client either way.
        var response = Notification_V1_ListNotificationsResponse()
        let limit = request.limit > 0 ? Int(request.limit) : notifications.count
        let start = min(max(Int(request.pageToken) ?? 0, 0), notifications.count)
        let end = min(start + limit, notifications.count)
        response.notifications = Array(notifications[start..<end])
        response.nextPageToken = end < notifications.count ? String(end) : ""
        response.readHorizonMs = nowMs
        return .success(response)
    }
}
