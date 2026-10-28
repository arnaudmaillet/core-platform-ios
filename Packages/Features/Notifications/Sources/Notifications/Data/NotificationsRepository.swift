import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

public enum NotificationsError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
    /// The server cannot do this yet: clearing (#1574) waits for backend #971.
    case unsupported
}

extension NotificationsError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
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
        /// Family supervision (#1106, backend #848): a link began, the
        /// other side ended it, or it ended because the teen turned 18. The
        /// sender is the other side.
        case supervisionStarted
        case supervisionEnded
        case supervisionCameOfAge
        case other

        /// A supervision notice: its row opens Family and Teens.
        public var isSupervision: Bool {
            self == .supervisionStarted || self == .supervisionEnded || self == .supervisionCameOfAge
        }
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
    /// Non-nil when the subject is an account (`SUBJECT_KIND_ACCOUNT`): the
    /// other side of a supervision, whose link the row opens (#1106).
    public let subjectAccountID: String?
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
        subjectAccountID: String? = nil,
        isRead: Bool,
        createdAt: Date
    ) {
        self.subjectAccountID = subjectAccountID
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
            subjectPreview: subjectPreview, subjectAccountID: subjectAccountID, isRead: true, createdAt: createdAt
        )
    }
}

/// One page of the viewer's notifications, most recent first, and where the
/// next one starts (#608).
public struct NotificationsPage: Equatable, Sendable {
    public let items: [NotificationItem]
    /// Nil when there are no more.
    public let nextPageToken: String?

    public init(items: [NotificationItem], nextPageToken: String?) {
        self.items = items
        self.nextPageToken = nextPageToken
    }
}

/// How far a clear reaches (#1574): everything up to the newest notification
/// the viewer was shown — one that arrives after it survives.
public struct NotificationsClearBound: Equatable, Sendable {
    public let newestID: String
    public let newestCreatedAt: Date

    public init(newestID: String, newestCreatedAt: Date) {
        self.newestID = newestID
        self.newestCreatedAt = newestCreatedAt
    }

    /// The newest of `items`; nil when there are none.
    public init?(newestOf items: [NotificationItem]) {
        guard let newest = items.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        self.init(newestID: newest.id, newestCreatedAt: newest.createdAt)
    }

    /// Whether a clear to this bound takes `item`.
    public func reaches(_ item: NotificationItem) -> Bool {
        item.id == newestID || item.createdAt <= newestCreatedAt
    }
}

/// Deletes a profile's notifications up to a bound on the server (#1574).
///
/// ⚠️ A SEAM, UNTIL THE CONTRACT HAS THE RPC: notification.v1 has no clear
/// yet (backend #971). The app hands the mock's in mock mode; nil elsewhere,
/// and the trash is not offered.
public typealias NotificationsClearing = @Sendable (_ profileID: String, _ bound: NotificationsClearBound) async throws -> Void

/// What the notifications UI consumes; implemented by `NotificationsRepository`,
/// faked in view-model tests.
public protocol NotificationsProviding: Sendable {
    /// A page of at most `limit` notifications: the first when `pageToken` is
    /// nil, otherwise the one that token starts (#608).
    func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage
    func markAllRead() async throws
    /// Marks these rows read on the server, one by one (`MarkRead`) — the
    /// rows the viewer has SEEN (#1572), not everything loaded.
    func markRead(_ items: [NotificationItem]) async throws
    /// The viewer's unread notification count, for the tab badge.
    func unreadCount() async throws -> Int
    /// Deletes the viewer's notifications up to `bound` on the server
    /// (#1574): the trash's commit, once its Undo toast has run out.
    func clearAll(through bound: NotificationsClearBound) async throws
    /// Whether push is paused (#1575): the server's "pause all".
    func pushPause() async throws -> PushPause
    /// Pauses push (or resumes it, `.off`); returns what the server now holds.
    func setPushPause(_ pause: PushPause) async throws -> PushPause
}

extension NotificationsProviding {
    /// A provider with no per-row read (a test's fake) marks nothing.
    public func markRead(_ items: [NotificationItem]) async throws {}
    /// A provider with no clear (a test's fake) clears nothing.
    public func clearAll(through bound: NotificationsClearBound) async throws {}
    /// A provider with no preferences (a test's fake) never pauses.
    public func pushPause() async throws -> PushPause { .off }
    public func setPushPause(_ pause: PushPause) async throws -> PushPause { pause }

    /// The first page's rows.
    public func loadNotifications(limit: Int32) async throws -> [NotificationItem] {
        try await loadNotifications(limit: limit, after: nil).items
    }
}

/// Reads the viewer's activity from notification.v1, hydrating what the
/// notification view leaves as ids: each sender's name and picture via
/// profile.v1, and — when a post client is supplied — the subject post's
/// thumbnail or text via post.v1.
public actor NotificationsRepository: NotificationsProviding, ViewerScoped {
    let notificationClient: any Notification_V1_NotificationServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let postClient: (any Post_V1_PostServiceClientInterface)?
    private let authSession: any AuthSessionProviding
    /// The server's clear (#1574): the mock's until backend #971; nil
    /// answers `.unsupported`.
    private let clear: NotificationsClearing?

    /// Who is signed in, and as which profile — shared with every other
    /// repository (`ViewerSession`), so a switch or a sign-out reaches all of them.
    private let viewer: any ViewerProviding
    /// Absence is cached with presence: a profile that could not be read is
    /// not asked for again on the next load — for `failedLookupLifetime`,
    /// then it is (#897). Both caches are bounded.
    private var actorCache: LookupCache<ProfileID, NotificationActor>
    private var previewCache: LookupCache<PostID, NotificationSubjectPreview>
    private let now: @Sendable () -> Date
    /// Bumped by every viewer change, so a lookup that left for the previous
    /// viewer and lands after the change is not kept for the new one.
    private var viewerGeneration = 0

    /// The people and posts kept between loads: a drawer's worth many times
    /// over (100 stored rows, two faces and one post each).
    public static let lookupCapacity = 500
    /// How long a failed lookup is believed.
    static let failedLookupLifetime: TimeInterval = 5 * 60

    /// The longest excerpt a text post contributes — two lines of a drawer
    /// row, with room for the ellipsis the label adds.
    static let excerptLimit = 140

    /// Where every sender this repository hydrates is reported (#1858).
    private let people: (any PeopleSightings)?

    public init(
        notificationClient: any Notification_V1_NotificationServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        postClient: (any Post_V1_PostServiceClientInterface)? = nil,
        authSession: any AuthSessionProviding,
        viewer: (any ViewerProviding)? = nil,
        lookupCapacity: Int = NotificationsRepository.lookupCapacity,
        clear: NotificationsClearing? = nil,
        people: (any PeopleSightings)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.people = people
        self.clear = clear
        self.actorCache = LookupCache(capacity: lookupCapacity, failureLifetime: Self.failedLookupLifetime)
        self.previewCache = LookupCache(capacity: lookupCapacity, failureLifetime: Self.failedLookupLifetime)
        self.now = now
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

    public func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
        let viewer = try await resolveViewerProfileID()

        var request = Notification_V1_ListNotificationsRequest()
        request.profileID = viewer.rawValue
        request.limit = limit
        request.pageToken = pageToken ?? ""
        let response = await notificationClient.listNotifications(request: request, headers: [:])
        let views: [Notification_V1_NotificationView]
        let nextToken: String
        switch response.result {
        case .success(let body):
            views = body.notifications
            nextToken = body.nextPageToken
        case .failure(let error): throw NotificationsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }

        // Two independent hydrations: people, and the posts they acted on.
        await hydrateActors(for: views)
        await hydratePreviews(for: views)
        return NotificationsPage(items: views.map(makeItem), nextPageToken: nextToken.isEmpty ? nil : nextToken)
    }

    public func markAllRead() async throws {
        let viewer = try await resolveViewerProfileID(forWrite: "markAllRead")
        var request = Notification_V1_MarkAllReadRequest()
        request.profileID = viewer.rawValue
        let response = await notificationClient.markAllRead(request: request, headers: [:])
        if let error = response.error {
            throw NotificationsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    public func clearAll(through bound: NotificationsClearBound) async throws {
        guard let clear else { throw NotificationsError.unsupported }
        let viewer = try await resolveViewerProfileID(forWrite: "clearAll")
        try await clear(viewer.rawValue, bound)
    }

    public func pushPause() async throws -> PushPause {
        let viewer = try await resolveViewerProfileID()
        var request = Notification_V1_GetNotificationPreferencesRequest()
        request.profileID = viewer.rawValue
        let response = await notificationClient.getNotificationPreferences(request: request, headers: [:])
        switch response.result {
        case .success(let body): return PushPause(pausedUntilMs: body.pausedUntilMs, now: Date())
        case .failure(let error):
            throw NotificationsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    /// Only the pause is sent: the update is partial on the server, so the
    /// categories and quiet hours Settings holds are left as they are.
    public func setPushPause(_ pause: PushPause) async throws -> PushPause {
        let viewer = try await resolveViewerProfileID(forWrite: "setPushPause")
        var request = Notification_V1_UpdateNotificationPreferencesRequest()
        request.profileID = viewer.rawValue
        request.pausedUntilMs = pause.pausedUntilMs
        let response = await notificationClient.updateNotificationPreferences(request: request, headers: [:])
        switch response.result {
        case .success(let body): return PushPause(pausedUntilMs: body.pausedUntilMs, now: Date())
        case .failure(let error):
            throw NotificationsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    public func markRead(_ items: [NotificationItem]) async throws {
        guard !items.isEmpty else { return }
        let viewer = try await resolveViewerProfileID(forWrite: "markRead")
        for item in items {
            var request = Notification_V1_MarkReadRequest()
            request.profileID = viewer.rawValue
            request.notificationID = item.id
            request.createdAtMs = Int64(item.createdAt.timeIntervalSince1970 * 1_000)
            let response = await notificationClient.markRead(request: request, headers: [:])
            if let error = response.error {
                throw NotificationsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
            }
        }
    }

    public func unreadCount() async throws -> Int {
        let viewer = try await resolveViewerProfileID()
        var request = Notification_V1_GetUnreadCountRequest()
        request.profileID = viewer.rawValue
        let response = await notificationClient.getUnreadCount(request: request, headers: [:])
        switch response.result {
        case .success(let body): return Int(body.unreadCount)
        case .failure(let error): throw NotificationsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    // MARK: - Viewer

    /// ⚠️ WHAT A LOOKUP ANSWERED IS THE VIEWER'S (#978). A post another viewer
    /// could not read (private, blocked, deleted for them) is remembered as
    /// missing for `failedLookupLifetime`; after a switch, the new viewer may
    /// well see it. A profile is read through the viewer's eyes too (blocks).
    /// Both caches start over, and lookups in flight are dropped on arrival.
    public func viewerDidChange(_ state: ViewerState) async {
        viewerGeneration += 1
        actorCache.removeAll()
        previewCache.removeAll()
    }

    /// How many answers each lookup cache holds, for tests.
    var lookupCounts: (actors: Int, previews: Int) { (actorCache.count, previewCache.count) }

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
        let asked = now()
        let generation = viewerGeneration
        let missing = wanted.filter { !actorCache.isKnown($0, now: asked) && !$0.rawValue.isEmpty }
        guard !missing.isEmpty else { return }

        let client = profileClient
        let fetched = await withTaskGroup(of: (ProfileID, Profile_V1_ProfileView?).self) { group in
            for id in missing {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id.rawValue
                    let response = await client.getProfileByID(request: request, headers: [:])
                    return (id, response.message)
                }
            }
            return await group.reduce(into: [(ProfileID, Profile_V1_ProfileView?)]()) { $0.append($1) }
        }
        let answered = now()
        guard generation == viewerGeneration else { return }
        for (id, view) in fetched {
            let actor = view.map { view in
                NotificationActor(
                    id: id,
                    name: view.displayName,
                    avatarURL: view.avatarURL.isEmpty ? nil : URL(string: view.avatarURL)
                )
            }
            actorCache.record(actor, for: id, now: answered)
        }
        people?.saw(fetched.compactMap { $0.1.map(AuthorSummary.init(profileView:)) })
    }

    /// The subject post's first still, or its text when it has no picture.
    /// Best-effort: without a post client, or for a post that cannot be read,
    /// the row simply has no preview.
    private func hydratePreviews(for views: [Notification_V1_NotificationView]) async {
        guard let postClient else { return }
        let subjects = views
            .filter { $0.subjectKind == .post && !$0.subjectID.isEmpty }
            .map { PostID($0.subjectID) }
        let asked = now()
        let generation = viewerGeneration
        let missing = Set(subjects).filter { !previewCache.isKnown($0, now: asked) }
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
        let answered = now()
        guard generation == viewerGeneration else { return }
        for (id, preview) in fetched {
            previewCache.record(preview, for: id, now: answered)
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
        let sender = actorCache.value(for: senderID)
        let postSubjectID: PostID? = view.subjectKind == .post ? PostID(view.subjectID) : nil
        let samples = Self.sampledOthers(of: view).compactMap { actorCache.value(for: $0) }
        return NotificationItem(
            id: view.notificationID,
            action: Self.action(from: view.kind),
            senderID: senderID,
            senderName: sender?.name ?? "Someone",
            senderAvatarURL: sender?.avatarURL,
            otherSenderCount: max(0, Int(view.senderCount) - 1),
            sampleSenders: samples,
            postSubjectID: postSubjectID,
            subjectPreview: postSubjectID.flatMap { previewCache.value(for: $0) },
            subjectAccountID: view.subjectKind == .account && !view.subjectID.isEmpty ? view.subjectID : nil,
            isRead: view.isRead,
            createdAt: Date(timeIntervalSince1970: TimeInterval(view.createdAtMs) / 1000)
        )
    }

    static func action(from kind: Notification_V1_NotificationKind) -> NotificationItem.Action {
        switch kind {
        case .reaction: .reaction
        case .comment: .comment
        case .reply: .reply
        case .mention: .mention
        case .supervisionStarted: .supervisionStarted
        case .supervisionEnded: .supervisionEnded
        case .supervisionCameOfAge: .supervisionCameOfAge
        // A kind this build doesn't know yet reads as generic activity.
        default: .other
        }
    }

    /// `write` names the caller when it is a write, so a guest reaching it is
    /// reported (`GateAudit`): the member gate should have stopped them first.
    /// The active profile, for a write — what `PushDeviceRegistering` asks.
    func activeProfileIDForWrite(_ write: String) async throws -> ProfileID {
        try await resolveViewerProfileID(forWrite: write)
    }

    private func resolveViewerProfileID(forWrite write: String? = nil) async throws -> ProfileID {
        do {
            return try await viewer.activeProfileID()
        } catch ViewerError.requiresMember {
            if let write { GateAudit.ungatedWrite(write) }
            throw NotificationsError.notAuthenticated
        } catch ViewerError.noProfileForAccount {
            throw NotificationsError.noProfileForAccount
        } catch let error as AccountProfilesReader.ReadError {
            throw NotificationsError.transport(message: error.message, failure: error.networkFailure)
        }
    }
}
