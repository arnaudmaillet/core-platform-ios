import CoreModels
import CoreNetworking
import CoreStorage
import Foundation
import PostGrid
import Testing
@testable import Profile

// MARK: - Fakes

/// engagement's saves, in memory: per profile, most recent first, a re-save
/// keeping its place — the backend's rules. `failing` makes every call fail
/// with that failure until cleared.
private actor FakeSavesServer: SavedPostsTransport {
    private(set) var lists: [String: [String]] = [:]
    /// Every write, in order: "save:p1", "unsave:p2".
    private(set) var writes: [String] = []
    private(set) var listCalls = 0
    var failing: NetworkFailure?
    /// Fails the writes only: the list still answers.
    var writesFailing: NetworkFailure?
    /// Refused for good (a deleted post).
    var gone: Set<String> = []
    var pageSize = 2
    /// Holds each write this long, counting it as started first.
    var writeDelay: Duration?
    private(set) var startedWrites = 0

    func slowWrites(_ delay: Duration?) { writeDelay = delay }

    init(lists: [String: [String]] = [:]) {
        self.lists = lists
    }

    func fail(with failure: NetworkFailure?) { failing = failure }
    func failWrites(with failure: NetworkFailure?) { writesFailing = failure }
    func setGone(_ ids: Set<String>) { gone = ids }
    func put(_ ids: [String], for profile: String) { lists[profile] = ids }

    func save(_ postID: String, account: String, profile: String) async throws {
        startedWrites += 1
        if let writeDelay { try? await Task.sleep(for: writeDelay) }
        if let failure = failing ?? writesFailing { throw SavedPostsError(failure) }
        if gone.contains(postID) { throw SavedPostsError(.refused(code: "not_found")) }
        writes.append("save:" + postID)
        var list = lists[profile] ?? []
        if !list.contains(postID) { list.insert(postID, at: 0) }
        lists[profile] = list
    }

    func unsave(_ postID: String, account: String, profile: String) async throws {
        if let failure = failing ?? writesFailing { throw SavedPostsError(failure) }
        writes.append("unsave:" + postID)
        lists[profile]?.removeAll { $0 == postID }
    }

    func list(profile: String, pageToken: String) async throws -> (postIDs: [String], next: String) {
        if let failing { throw SavedPostsError(failing) }
        listCalls += 1
        let all = lists[profile] ?? []
        let start = Int(pageToken) ?? 0
        let end = min(start + pageSize, all.count)
        return (Array(all[start..<end]), end < all.count ? String(end) : "")
    }
}

/// One isolated world: its own defaults, scope, pile, outbox and sync.
@MainActor
private struct World {
    let defaults: UserDefaults
    let scope: StorageScope
    let store: PostBookmarkStore
    let outbox: SaveOutbox
    let server: FakeSavesServer
    let sync: SavedPostsSync
    let connectivity = ConnectivityMonitor(offlineGrace: 0)

    static let member = StorageScope.Owner.member(account: "acct-1", profile: "prof-1")

    init(owner: StorageScope.Owner = World.member, server: FakeSavesServer = FakeSavesServer(), pile: [String] = []) {
        let defaults = UserDefaults(suiteName: "saved-sync-\(UUID().uuidString)")!
        self.defaults = defaults
        scope = StorageScope(owner: owner)
        store = PostBookmarkStore(defaults: defaults, scope: scope)
        // The pile an install already had, written oldest first.
        for id in pile.reversed() { store.toggle(id) }
        outbox = SaveOutbox(defaults: defaults)
        self.server = server
        sync = SavedPostsSync(
            store: store, outbox: outbox, transport: server, scope: scope, defaults: defaults,
            retryDelays: [0.02]
        )
        sync.connectivity = connectivity
        store.sync = sync
    }
}

/// Polls until `condition` holds, or the budget runs out.
@MainActor
private func settle(until condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Write through

@MainActor
struct SavedPostsWriteThroughTests {
    @Test func aSaveAndAnUnsaveReachTheServer() async {
        let world = World()
        world.sync.start()

        world.store.toggle("p1")
        #expect(await settle { await world.server.writes == ["save:p1"] })
        world.store.toggle("p1")
        #expect(await settle { await world.server.writes == ["save:p1", "unsave:p1"] })
        #expect(await settle { world.outbox.entries.isEmpty })
    }

    /// Offline, the change waits in the outbox — across launches — and goes
    /// when the network is back.
    @Test func anOfflineSaveIsReplayedWhenTheNetworkReturns() async {
        let world = World()
        await world.server.fail(with: .offline)
        world.sync.start()

        world.store.toggle("p1")
        #expect(await settle { world.outbox.entries.map(\.postID) == ["p1"] })
        #expect(await world.server.writes.isEmpty)
        // A later launch reads the same queue.
        #expect(SaveOutbox(defaults: world.defaults).entries.map(\.postID) == ["p1"])

        await world.server.fail(with: nil)
        world.connectivity.report(online: false)
        world.connectivity.report(online: true)
        #expect(await settle { await world.server.writes == ["save:p1"] })
        #expect(await settle { world.outbox.entries.isEmpty })
    }

    /// A save made while another is on its way goes in the same flush, not
    /// at the next network event.
    @Test func aSaveMadeDuringASendFollowsIt() async {
        let world = World()
        await world.server.slowWrites(.milliseconds(80))
        world.sync.start()

        world.store.toggle("p1")
        #expect(await settle { await world.server.startedWrites == 1 })
        world.store.toggle("p2")

        #expect(await settle { await world.server.writes == ["save:p1", "save:p2"] })
        #expect(await settle { world.outbox.entries.isEmpty })
    }

    /// Flipped three times offline, only where the viewer left it goes.
    @Test func onlyTheLastStateOfAPostIsQueued() async {
        let world = World()
        await world.server.fail(with: .offline)

        world.store.toggle("p1")
        world.store.toggle("p1")
        world.store.toggle("p1")

        #expect(world.outbox.entries.count == 1)
        #expect(world.outbox.entries.first?.isSaved == true)
    }

    /// A post the server refuses for good leaves the queue and holds nothing
    /// behind it.
    @Test func aRefusedSaveIsDroppedAndTheNextGoes() async {
        let world = World()
        await world.server.setGone(["gone"])
        world.store.toggle("gone")
        world.store.toggle("p2")

        await world.sync.flush()

        #expect(await world.server.writes == ["save:p2"])
        #expect(world.outbox.entries.isEmpty)
    }

    /// A guest's pile stays on the device: nothing is queued for a server
    /// that keeps a member's saves only.
    @Test func aGuestsSaveStaysOnTheDevice() async {
        let world = World(owner: .guest)
        world.store.toggle("p1")

        #expect(world.outbox.entries.isEmpty)
        #expect(world.store.savedPostIDs == ["p1"])
    }

    /// Another account's queued save waits for its account rather than going
    /// with this one's token.
    @Test func anotherAccountsSaveWaitsForIt() async {
        let world = World()
        world.outbox.record(postID: "theirs", isSaved: true, account: "acct-2", profile: "prof-9")

        await world.sync.flush()

        #expect(await world.server.writes.isEmpty)
        #expect(world.outbox.entries.map(\.postID) == ["theirs"])
    }
}

// MARK: - Reading the server

@MainActor
struct SavedPostsReadTests {
    /// A new device: nothing in the pile, the server's whole list — every
    /// page — arrives in its order.
    @Test func theServersListFillsAnEmptyPile() async {
        let world = World(server: FakeSavesServer(lists: ["prof-1": ["s1", "s2", "s3", "s4", "s5"]]))

        await world.sync.refresh(force: true)

        #expect(world.store.savedPostIDs == ["s1", "s2", "s3", "s4", "s5"])
        #expect(world.store.isSaved("s5"))
    }

    /// The pile already on the device is pushed once, oldest first, so the
    /// server's list comes back in the device's order — with what was saved
    /// elsewhere where the server has it.
    @Test func theDevicesPileIsPushedOnceOldestFirst() async {
        let server = FakeSavesServer(lists: ["prof-1": ["elsewhere"]])
        let world = World(server: server, pile: ["newest", "older", "oldest"])

        await world.sync.refresh(force: true)

        #expect(await server.writes == ["save:oldest", "save:older", "save:newest"])
        #expect(world.store.savedPostIDs == ["newest", "older", "oldest", "elsewhere"])

        await world.sync.refresh(force: true)
        #expect(await server.writes.count == 3, "the pile is pushed once per profile")
    }

    /// Unsaved on another device: it leaves this one's pile and its glyph.
    @Test func whatTheServerNoLongerHasLeavesThePile() async {
        let server = FakeSavesServer()
        let world = World(server: server, pile: ["kept", "dropped"])
        await world.sync.refresh(force: true)
        await server.put(["kept"], for: "prof-1")

        await world.sync.refresh(force: true)

        #expect(world.store.savedPostIDs == ["kept"])
        #expect(!world.store.isSaved("dropped"))
    }

    /// An unsave the server has not heard yet still stands over its list.
    @Test func aQueuedUnsaveStandsOverTheList() async {
        let server = FakeSavesServer()
        let world = World(server: server, pile: ["a", "b"])
        await world.sync.refresh(force: true)
        #expect(await server.lists["prof-1"] == ["a", "b"])

        await server.failWrites(with: .offline)
        world.store.toggle("a")
        await world.sync.refresh(force: true)

        #expect(world.outbox.entries.map(\.postID) == ["a"])
        #expect(world.store.savedPostIDs == ["b"], "the list still holds a; the queued unsave wins")

        await server.failWrites(with: nil)
        await world.sync.refresh(force: true)
        #expect(await server.lists["prof-1"] == ["b"])
        #expect(world.store.savedPostIDs == ["b"])
    }

    /// Offline, the pile stands and nothing is marked pushed.
    @Test func anOfflineReadLeavesThePileAndRetriesThePush() async {
        let server = FakeSavesServer()
        await server.fail(with: .offline)
        let world = World(server: server, pile: ["p1"])

        await world.sync.refresh(force: true)
        #expect(world.store.savedPostIDs == ["p1"])

        await server.fail(with: nil)
        await world.sync.refresh(force: true)
        #expect(await server.writes == ["save:p1"])
        #expect(world.store.savedPostIDs == ["p1"])
    }

    /// A list asked for one profile never lands in another's pile.
    @Test func aListNeverLandsInAnotherProfilesPile() {
        let defaults = UserDefaults(suiteName: "saved-sync-\(UUID().uuidString)")!
        let scope = StorageScope(owner: .member(account: "acct-1", profile: "prof-2"))
        let store = PostBookmarkStore(defaults: defaults, scope: scope)

        let wrote = store.replaceSaved(with: ["x"], owner: World.member)

        #expect(!wrote)
        #expect(store.savedPostIDs.isEmpty)
    }

    /// A list read moments ago is not asked again on the next appearance.
    @Test func aFreshListIsNotAskedAgain() async {
        let server = FakeSavesServer(lists: ["prof-1": ["s1"]])
        let world = World(server: server)

        await world.sync.refreshFromServer()
        await world.sync.refreshFromServer()

        #expect(await server.listCalls == 1)
    }
}

// MARK: - The Saved tab

private actor SavedTilesGallery: ProfileGalleryProviding {
    func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
    func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
    func posts(ids: [String]) async throws -> [GalleryPost] {
        ids.map { GalleryPost(id: PostID($0), kind: .photo, isRepost: false, thumbnailURL: nil, caption: "", publishedAtMS: 0) }
    }
}

private actor OwnProfile: ProfileProviding {
    let profile = UserProfile(
        id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", bio: "",
        avatarURL: nil, websiteURL: nil, isVerified: false,
        followerCount: .exact(0), followingCount: .exact(0), reactionCount: .unavailable
    )
    func currentUserProfile() async throws -> UserProfile { profile }
    func profile(id: ProfileID) async throws -> UserProfile { profile }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile {
        profile
    }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { profile }
}

@MainActor
private final class SavedPageLog {
    var states: [ProfileViewModel.GalleryPageState] = []
}

@MainActor
struct SavedTabServerTests {
    /// A new device opens Saved on the server's list, not on "nothing saved".
    @Test func theSavedTabShowsTheServersList() async {
        let world = World(server: FakeSavesServer(lists: ["prof-1": ["s1", "s2"]]))
        let viewModel = ProfileViewModel(
            repository: OwnProfile(), gallery: SavedTilesGallery(), bookmarks: world.store, source: .currentUser
        )
        let log = SavedPageLog()
        viewModel.onGalleryChange = { log.states.append($0.saved) }

        viewModel.viewDidLoad()
        viewModel.loadSavedPosts()

        #expect(await settle {
            if case .content(let tiles) = log.states.last { return tiles.map(\.id.rawValue) == ["s1", "s2"] }
            return false
        })
        #expect(!log.states.contains(.empty(message: "")), "never said empty before the list answered: \(log.states)")
    }
}
