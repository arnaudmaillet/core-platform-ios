import CoreContracts
import CoreNetworking
import CoreStorage
import Foundation
import UIKit

// MARK: - The wire

/// engagement.v1's saves (#837), as the viewer: what `SavedPostsSync` sends
/// and reads. Tests hand in their own.
public protocol SavedPostsTransport: Sendable {
    /// Idempotent: a re-save keeps its first save time.
    func save(_ postID: String, account: String, profile: String) async throws
    /// Idempotent: unsaving what isn't saved is a no-op.
    func unsave(_ postID: String, account: String, profile: String) async throws
    /// One page of the profile's saves, most recently saved first, and the
    /// token of the next (empty on the last).
    func list(profile: String, pageToken: String) async throws -> (postIDs: [String], next: String)
}

/// Why a save or a list read failed (#837).
public struct SavedPostsError: NetworkFailureCarrying, Equatable {
    public let failure: NetworkFailure
    public var networkFailure: NetworkFailure? { failure }

    public init(_ failure: NetworkFailure) {
        self.failure = failure
    }
}

/// `SavedPostsTransport` over the edge. Failures are `SavedPostsError`s.
public struct EngagementSavedPosts: SavedPostsTransport {
    private let client: any Engagement_V1_EngagementServiceClientInterface

    public init(client: any Engagement_V1_EngagementServiceClientInterface) {
        self.client = client
    }

    public func save(_ postID: String, account: String, profile: String) async throws {
        var request = Engagement_V1_SavePostRequest()
        request.accountID = account
        request.profileID = profile
        request.postID = postID
        if let error = await client.savePost(request: request, headers: [:]).error {
            throw SavedPostsError(NetworkFailure(error))
        }
    }

    public func unsave(_ postID: String, account: String, profile: String) async throws {
        var request = Engagement_V1_UnsavePostRequest()
        request.accountID = account
        request.profileID = profile
        request.postID = postID
        if let error = await client.unsavePost(request: request, headers: [:]).error {
            throw SavedPostsError(NetworkFailure(error))
        }
    }

    public func list(profile: String, pageToken: String) async throws -> (postIDs: [String], next: String) {
        var request = Engagement_V1_ListSavedPostsRequest()
        request.profileID = profile
        request.limit = 100
        request.pageToken = pageToken
        let response = await client.listSavedPosts(request: request, headers: [:])
        if let error = response.error { throw SavedPostsError(NetworkFailure(error)) }
        guard let page = response.message else { throw SavedPostsError(.server(code: "empty_response")) }
        return (page.posts.map(\.postID), page.nextPageToken)
    }
}

// MARK: - The outbox

/// The saves the server has not heard yet (#837), persisted across launches:
/// one entry per profile and post, the latest state winning — both RPCs are
/// idempotent, so only where the viewer left the post matters, not how many
/// times they flipped it.
///
/// ⚠️ ONE LIST FOR EVERY ACCOUNT, like `LikeOutbox`: an entry goes with its
/// own account's token only, and waits for that account's return rather than
/// being dropped by a sign-out.
public final class SaveOutbox: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var account: String
        public var profile: String
        public var postID: String
        public var isSaved: Bool
        /// Bumped on every change: a send that lands after the viewer flipped
        /// the post again completes nothing (`complete(_:)`).
        public var sequence: Int
    }

    private static let key = "saves.outbox"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var _entries: [Entry]
    private var nextSequence: Int

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        _entries = stored
        nextSequence = (stored.map(\.sequence).max() ?? 0) + 1
    }

    /// Oldest change first.
    public var entries: [Entry] { lock.withLock { _entries } }

    /// Queues where the viewer left `postID`, replacing what was queued for it.
    public func record(postID: String, isSaved: Bool, account: String, profile: String) {
        lock.withLock {
            _entries.removeAll { $0.profile == profile && $0.postID == postID }
            _entries.append(Entry(
                account: account, profile: profile, postID: postID, isSaved: isSaved, sequence: nextSequence
            ))
            nextSequence += 1
            persist()
        }
    }

    /// The server has `entry`: it leaves, unless the viewer changed the post
    /// again meanwhile (that newer entry still has to go).
    public func complete(_ entry: Entry) {
        lock.withLock {
            _entries.removeAll { $0.sequence == entry.sequence }
            persist()
        }
    }

    private func persist() {
        if _entries.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(_entries) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

// MARK: - The sync

/// Keeps the device's saved pile and the server's in step (#837).
///
/// - **Write through.** Every toggle (`PostBookmarkStore.toggle`) lands in
///   the outbox and goes now; a send that fails for a reason a retry may
///   cure is retried after a growing wait, and at once when the network
///   comes back. A refusal for good (a deleted post) is dropped: the next
///   list puts the pile right.
/// - **Reconcile once.** The first time a profile's list is read, the pile
///   already on the device is pushed, oldest first, so the server's order —
///   save time, the first one kept — matches the one the device showed.
/// - **Read the server.** The Saved tab asks for the list
///   (`refreshFromServer`): every page, then what the outbox still holds on
///   top, replacing the pile.
@MainActor
public final class SavedPostsSync: PostSaveSyncing {
    private let store: PostBookmarkStore
    private let outbox: SaveOutbox
    private let transport: any SavedPostsTransport
    private let scope: StorageScope
    private let defaults: UserDefaults
    /// Waits after a failed send, the last repeated.
    private let retryDelays: [TimeInterval]
    /// How long a list read stays good enough: the device's own saves are in
    /// the pile already; the list only brings what another device did.
    private let listFreshness: TimeInterval
    private let now: @Sendable () -> Date
    private(set) var failures = 0
    private var isSending = false
    private var timer: Timer?
    private var refreshing: Task<Void, Never>?
    private var lastList: (profile: String, at: Date)?
    /// The toggles made while a list is on its way, in order: one sent
    /// before the list was read is in it, one sent after is not, and the
    /// outbox no longer says which — so every one of them wins.
    private var editsDuringRead: [(profile: String, postID: String, isSaved: Bool)] = []
    /// Removed with the sync (the bag's deinit, not a main-actor one).
    private let observers = ObserverTokens()
    /// Whose recoveries flush the outbox; read by `start()`. Tests hand in
    /// their own — ⚠️ never flip `.shared`, other suites listen to it.
    var connectivity: ConnectivityMonitor = .shared

    /// The profiles whose device pile was pushed (`reconcile`).
    private static let reconciledKey = "saves.reconciledProfiles"
    /// A list longer than this many pages is cut: the Saved tab hydrates
    /// every id it holds.
    static let maxPages = 20

    public init(
        store: PostBookmarkStore,
        outbox: SaveOutbox,
        transport: any SavedPostsTransport,
        scope: StorageScope = .shared,
        defaults: UserDefaults = .standard,
        retryDelays: [TimeInterval] = [2, 5, 15, 60],
        listFreshness: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.outbox = outbox
        self.transport = transport
        self.scope = scope
        self.defaults = defaults
        self.retryDelays = retryDelays
        self.listFreshness = listFreshness
        self.now = now
        #if DEBUG
        // The pile's QA hooks (`PostBookmarkStore`): a seeded pile is pushed
        // like an upgrading install's, so the list keeps it.
        if ProcessInfo.processInfo.arguments.contains("-seed-bookmarks") {
            defaults.removeObject(forKey: Self.reconciledKey)
        }
        #endif
    }

    /// Starts sending: now for what an earlier launch left, then on every
    /// return of the network, foreground and viewer change.
    public func start() {
        let center = NotificationCenter.default
        observers.tokens = [
            center.addObserver(
                forName: ConnectivityMonitor.didRecoverNotification, object: connectivity, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.failures = 0
                    self?.sendSoon()
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendSoon() }
            },
            // An account back after a sign-out finds its queued saves.
            center.addObserver(forName: StorageScope.didChangeNotification, object: scope, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendSoon() }
            }
        ]
        sendSoon()
    }

    // MARK: PostSaveSyncing

    public nonisolated func saveDidChange(postID: String, isSaved: Bool, owner: StorageScope.Owner) {
        // A guest's pile (and one whose profile is not known yet) stays on
        // the device: the server keeps a member profile's saves only.
        guard case .member(let account, let profile?) = owner else { return }
        outbox.record(postID: postID, isSaved: isSaved, account: account, profile: profile)
        Task { @MainActor in
            if self.refreshing != nil {
                self.editsDuringRead.append((profile, postID, isSaved))
            }
            self.sendSoon()
        }
    }

    public nonisolated var readsServer: Bool {
        if case .member(_, _?) = scope.owner { return true }
        return false
    }

    public nonisolated func refreshFromServer() async {
        await refresh(force: false)
    }

    // MARK: Sending

    private func sendSoon() {
        timer?.invalidate()
        timer = nil
        Task { await flush() }
    }

    /// Sends every queued change of the signed-in account, oldest first;
    /// stops at the first that a retry may cure and tries again later.
    func flush() async {
        guard !isSending else { return }
        guard case .member(let account, _) = scope.owner else { return }
        isSending = true
        var failed = false
        // A change queued while this one sends goes in the same flush: its
        // own `sendSoon` found this one busy and returned.
        var tried = Set<Int>()
        while !failed, let entry = outbox.entries.first(where: { $0.account == account && !tried.contains($0.sequence) }) {
            tried.insert(entry.sequence)
            do {
                if entry.isSaved {
                    try await transport.save(entry.postID, account: entry.account, profile: entry.profile)
                } else {
                    try await transport.unsave(entry.postID, account: entry.account, profile: entry.profile)
                }
                outbox.complete(entry)
                failures = 0
            } catch {
                guard Self.isRetryable(error) else {
                    // Refused for good: a post deleted since, a profile gone.
                    // The next list says what the server kept.
                    outbox.complete(entry)
                    continue
                }
                failed = true
                failures += 1
            }
        }
        isSending = false
        guard failed else { return }
        let delay = retryDelays[min(failures - 1, retryDelays.count - 1)]
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.flush() }
            }
        }
    }

    /// Whether the same send may succeed later. An expired session
    /// (`unauthenticated`) counts: the entry waits for its account.
    static func isRetryable(_ error: any Error) -> Bool {
        guard let failure = NetworkFailure.of(error) else { return true }
        if case .refused(let code) = failure { return code == "unauthenticated" }
        return failure.isRetryable
    }

    // MARK: Reading

    /// Pushes the device's pile once, then replaces it with the server's
    /// list. A list read less than `listFreshness` ago is not asked again
    /// unless `force`d. Concurrent callers share one read.
    func refresh(force: Bool) async {
        if let refreshing {
            await refreshing.value
            return
        }
        guard case .member(let account, let profile?) = scope.owner else { return }
        if !force, let lastList, lastList.profile == profile, now().timeIntervalSince(lastList.at) < listFreshness {
            return
        }
        let task = Task { await self.readList(account: account, profile: profile) }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func readList(account: String, profile: String) async {
        let owner = StorageScope.Owner.member(account: account, profile: profile)
        editsDuringRead = []
        defer { editsDuringRead = [] }
        // What this device changed reaches the server before its list is read.
        await flush()
        do {
            try await reconcile(account: account, profile: profile, owner: owner)
            var ids: [String] = []
            var token = ""
            var pages = 0
            repeat {
                let page = try await transport.list(profile: profile, pageToken: token)
                ids += page.postIDs
                token = page.next
                pages += 1
            } while !token.isEmpty && pages < Self.maxPages
            // What the server has not heard yet still stands on top: a save
            // queued offline, or one made while the list was on its way.
            var seen = Set(ids)
            for entry in outbox.entries where entry.profile == profile {
                if entry.isSaved {
                    if !seen.contains(entry.postID) {
                        ids.insert(entry.postID, at: 0)
                        seen.insert(entry.postID)
                    }
                } else {
                    ids.removeAll { $0 == entry.postID }
                }
            }
            for edit in editsDuringRead where edit.profile == profile {
                ids.removeAll { $0 == edit.postID }
                if edit.isSaved { ids.insert(edit.postID, at: 0) }
            }
            if store.replaceSaved(with: Self.deduplicated(ids), owner: owner) {
                lastList = (profile, now())
            }
        } catch {
            // Offline, or the server is down: the pile stands as it is.
        }
    }

    /// The device's pile, pushed once per profile, oldest first: the server
    /// keeps a save's first time, so its list comes back in the order the
    /// device showed, with saves from elsewhere where they were.
    private func reconcile(account: String, profile: String, owner: StorageScope.Owner) async throws {
        var done = Set(defaults.stringArray(forKey: Self.reconciledKey) ?? [])
        guard !done.contains(profile), scope.owner == owner else { return }
        for id in store.savedPostIDs.reversed() {
            do {
                try await transport.save(id, account: account, profile: profile)
            } catch where !Self.isRetryable(error) {
                // A post gone since it was saved: nothing to push.
            }
        }
        done.insert(profile)
        defaults.set(Array(done), forKey: Self.reconciledKey)
    }

    /// Notification tokens, removed when the sync goes.
    private final class ObserverTokens: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    private static func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
