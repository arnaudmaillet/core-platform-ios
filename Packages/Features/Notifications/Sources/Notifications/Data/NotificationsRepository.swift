import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

public enum NotificationsError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    case transport(message: String)
}

/// A person behind a notification: who, and their picture when they have one.
public struct NotificationActor: Equatable, Sendable {
    public let id: ProfileID
    public let name: String
    /// Nil when the profile has no picture — the row draws initials instead.
    public let avatarURL: URL?

    public init(id: ProfileID, name: String, avatarURL: URL?) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// What the row can show of the post a notification is about: its first
/// picture, or — for a text post, which has none — the opening of its text.
public struct NotificationSubjectPreview: Equatable, Sendable {
    /// A still of the post's first page (a video's poster, never the video).
    public let thumbnailURL: URL?
    /// The post's text, for a post with no picture to show.
    public let excerpt: String?

    public init(thumbnailURL: URL?, excerpt: String?) {
        self.thumbnailURL = thumbnailURL
        self.excerpt = excerpt
    }
}

/// One activity-feed row, hydrated with the sender's display name and picture
/// (the notification.v1 view carries only ids). Aggregated notifications ("X
/// and N others") keep the primary sender plus a count, and the other senders
/// the server sampled, for the stacked avatars.
public struct NotificationItem: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Hashable, Sendable {
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
    public let senderAvatarURL: URL?
    /// Aggregated senders beyond the primary one ("and N others").
    public let otherSenderCount: Int
    /// Other senders the server named (`sample_sender_ids`), most recent
    /// first, never including the primary — for the second avatar. May be
    /// fewer than `otherSenderCount`: the server samples at most five.
    public let sampleSenders: [NotificationActor]
    /// Non-nil when the subject is a post — the tap target for `.post` routing.
    public let postSubjectID: PostID?
    /// The subject post's thumbnail or text, when it could be read.
    public let subjectPreview: NotificationSubjectPreview?
    public let isRead: Bool
    public let createdAt: Date

    public init(
        id: String,
        action: Action,
        senderID: ProfileID,
        senderName: String,
        senderAvatarURL: URL? = nil,
        otherSenderCount: Int,
        sampleSenders: [NotificationActor] = [],
        postSubjectID: PostID?,
        subjectPreview: NotificationSubjectPreview? = nil,
        isRead: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.action = action
        self.senderID = senderID
        self.senderName = senderName
        self.senderAvatarURL = senderAvatarURL
        self.otherSenderCount = otherSenderCount
        self.sampleSenders = sampleSenders
        self.postSubjectID = postSubjectID
        self.subjectPreview = subjectPreview
        self.isRead = isRead
        self.createdAt = createdAt
    }

    /// The primary sender as an actor.
    public var sender: NotificationActor {
        NotificationActor(id: senderID, name: senderName, avatarURL: senderAvatarURL)
    }

    /// The same row, read.
    public func markedRead() -> NotificationItem {
        NotificationItem(
            id: id, action: action, senderID: senderID, senderName: senderName,
            senderAvatarURL: senderAvatarURL, otherSenderCount: otherSenderCount,
            sampleSenders: sampleSenders, postSubjectID: postSubjectID,
            subjectPreview: subjectPreview, isRead: true, createdAt: createdAt
        )
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

/// Reads the viewer's activity from notification.v1, hydrating what the
/// notification view leaves as ids: each sender's name and picture via
/// profile.v1, and — when a post client is supplied — the subject post's
/// thumbnail or text via post.v1.
public actor NotificationsRepository: NotificationsProviding {
    private let notificationClient: any Notification_V1_NotificationServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let postClient: (any Post_V1_PostServiceClientInterface)?
    private let authSession: any AuthSessionProviding

    /// Who is signed in, and as which profile — shared with every other
    /// repository (`ViewerSession`), so a switch or a sign-out reaches all of them.
    private let viewer: any ViewerProviding
    /// Absence is cached with presence: a profile that could not be read is
    /// not asked for again on the next load.
    private var actorCache: [ProfileID: NotificationActor?] = [:]
    private var previewCache: [PostID: NotificationSubjectPreview?] = [:]

    /// The longest excerpt a text post contributes — two lines of a drawer
    /// row, with room for the ellipsis the label adds.
    static let excerptLimit = 140

    public init(
        notificationClient: any Notification_V1_NotificationServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        postClient: (any Post_V1_PostServiceClientInterface)? = nil,
        authSession: any AuthSessionProviding,
        viewer: (any ViewerProviding)? = nil
    ) {
        self.notificationClient = notificationClient
        self.profileClient = profileClient
        self.postClient = postClient
        self.authSession = authSession
        // Nil only outside the app (tests, previews): a session of its own,
        // resolving through this repository's profile client.
        self.viewer = viewer ?? ViewerSession(authSession: authSession) { [profileClient] account in
            try await AccountProfilesReader.profileIDs(ofAccount: account.rawValue, using: profileClient)
                .map { ProfileID($0) }
        }
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

        // Two independent hydrations: people, and the posts they acted on.
        await hydrateActors(for: views)
        await hydratePreviews(for: views)
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

    /// Names and pictures for every primary sender, plus the first sampled
    /// other sender of each row — the second face of a stacked avatar. The
    /// rest of a sample is never drawn, so it is never fetched.
    private func hydrateActors(for views: [Notification_V1_NotificationView]) async {
        var wanted = Set<ProfileID>()
        for view in views {
            wanted.insert(ProfileID(view.senderProfileID))
            if let second = Self.sampledOthers(of: view).first { wanted.insert(second) }
        }
        let missing = wanted.filter { actorCache[$0] == nil && !$0.rawValue.isEmpty }
        guard !missing.isEmpty else { return }

        let client = profileClient
        let fetched = await withTaskGroup(of: (ProfileID, NotificationActor?).self) { group in
            for id in missing {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id.rawValue
                    let response = await client.getProfileByID(request: request, headers: [:])
                    guard let view = response.message else { return (id, nil) }
                    return (id, NotificationActor(
                        id: id,
                        name: view.displayName,
                        avatarURL: view.avatarURL.isEmpty ? nil : URL(string: view.avatarURL)
                    ))
                }
            }
            return await group.reduce(into: [(ProfileID, NotificationActor?)]()) { $0.append($1) }
        }
        for (id, actor) in fetched {
            actorCache[id] = .some(actor)
        }
    }

    /// The subject post's first still, or its text when it has no picture.
    /// Best-effort: without a post client, or for a post that cannot be read,
    /// the row simply has no preview.
    private func hydratePreviews(for views: [Notification_V1_NotificationView]) async {
        guard let postClient else { return }
        let subjects = views
            .filter { $0.subjectKind == .post && !$0.subjectID.isEmpty }
            .map { PostID($0.subjectID) }
        let missing = Set(subjects).filter { previewCache[$0] == nil }
        guard !missing.isEmpty else { return }

        let fetched = await withTaskGroup(of: (PostID, NotificationSubjectPreview?).self) { group in
            for id in missing {
                group.addTask {
                    var request = Post_V1_GetPostRequest()
                    request.postID = id.rawValue
                    let response = await postClient.getPost(request: request, headers: [:])
                    guard let view = response.message else { return (id, nil) }
                    return (id, Self.preview(of: view))
                }
            }
            return await group.reduce(into: [(PostID, NotificationSubjectPreview?)]()) { $0.append($1) }
        }
        for (id, preview) in fetched {
            previewCache[id] = .some(preview)
        }
    }

    /// A post's preview: its first page's still, or its text when it has no
    /// picture at all.
    static func preview(of post: Post_V1_PostView) -> NotificationSubjectPreview? {
        if let first = post.attachments.first {
            // `thumbnail_url` is the still the wire promises for every kind. A
            // photo without one falls back to its own URL; a video never does
            // — an image pipeline cannot decode a clip.
            let still = first.thumbnailURL.isEmpty
                ? (first.mimeType.hasPrefix("image/") ? first.cdnURL : "")
                : first.thumbnailURL
            return NotificationSubjectPreview(
                thumbnailURL: still.isEmpty ? nil : URL(string: still), excerpt: nil
            )
        }
        let text = post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let excerpt = text.count > excerptLimit ? String(text.prefix(excerptLimit)) + "…" : text
        return NotificationSubjectPreview(thumbnailURL: nil, excerpt: excerpt)
    }

    /// The sampled senders other than the primary, in the server's order.
    static func sampledOthers(of view: Notification_V1_NotificationView) -> [ProfileID] {
        var seen: Set<String> = [view.senderProfileID]
        return view.sampleSenderIds.compactMap { id in
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return ProfileID(id)
        }
    }

    private func makeItem(from view: Notification_V1_NotificationView) -> NotificationItem {
        let senderID = ProfileID(view.senderProfileID)
        let sender = actorCache[senderID] ?? nil
        let postSubjectID: PostID? = view.subjectKind == .post ? PostID(view.subjectID) : nil
        let samples = Self.sampledOthers(of: view).compactMap { actorCache[$0] ?? nil }
        return NotificationItem(
            id: view.notificationID,
            action: Self.action(from: view.kind),
            senderID: senderID,
            senderName: sender?.name ?? "Someone",
            senderAvatarURL: sender?.avatarURL,
            otherSenderCount: max(0, Int(view.senderCount) - 1),
            sampleSenders: samples,
            postSubjectID: postSubjectID,
            subjectPreview: postSubjectID.flatMap { previewCache[$0] ?? nil },
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
        do {
            return try await viewer.activeProfileID()
        } catch ViewerError.requiresMember {
            throw NotificationsError.notAuthenticated
        } catch ViewerError.noProfileForAccount {
            throw NotificationsError.noProfileForAccount
        } catch let error as AccountProfilesReader.ReadError {
            throw NotificationsError.transport(message: error.message)
        }
    }
}
