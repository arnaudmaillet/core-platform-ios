import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import PostGrid
import Testing
@testable import Profile

// The Liked tab, and someone else's Saved tab (#411, #837).

private func tile(_ id: String) -> GalleryPost {
    GalleryPost(id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil, caption: id, publishedAtMS: 0)
}

private actor CorporaProfile: ProfileProviding {
    let profile: UserProfile
    init(_ id: String) {
        profile = UserProfile(
            id: ProfileID(id), handle: "ada", displayName: "Ada", bio: "",
            avatarURL: nil, websiteURL: nil, isVerified: false,
            followerCount: .exact(0), followingCount: .exact(0), reactionCount: .unavailable
        )
    }
    func currentUserProfile() async throws -> UserProfile { profile }
    func profile(id: ProfileID) async throws -> UserProfile { profile }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
        .other(isFollowing: false, isBlocked: false)
    }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile {
        profile
    }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { profile }
}

/// Serves Liked and Saved by profile; records who asked for what.
private actor CorporaGallery: ProfileGalleryProviding {
    var liked: [String: [GalleryPost]]
    var saved: [String: [GalleryPost]]
    private(set) var likedAsks: [String] = []
    private(set) var savedAsks: [String] = []

    init(liked: [String: [GalleryPost]] = [:], saved: [String: [GalleryPost]] = [:]) {
        self.liked = liked
        self.saved = saved
    }

    func setSaved(_ posts: [GalleryPost], for id: String) { saved[id] = posts }

    func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [tile("own-1")] }
    func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
    func posts(ids: [String]) async throws -> [GalleryPost] { ids.map(tile) }
    func likedPosts(of profileID: ProfileID) async throws -> [GalleryPost] {
        likedAsks.append(profileID.rawValue)
        return liked[profileID.rawValue] ?? []
    }
    func savedPosts(of profileID: ProfileID) async throws -> [GalleryPost] {
        savedAsks.append(profileID.rawValue)
        return saved[profileID.rawValue] ?? []
    }
}

@MainActor
private final class Snapshots {
    var all: [ProfileViewModel.GallerySnapshot] = []
    var last: ProfileViewModel.GallerySnapshot? { all.last }
}

@MainActor
private func settle(until condition: () async -> Bool) async -> Bool {
    // A look budget, not a deadline: a starved runner waits longer.
    for _ in 0..<6_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
struct EngagementTabsTests {
    private func load(
        _ source: ProfileViewModel.Source, gallery: CorporaGallery
    ) async -> (ProfileViewModel, Snapshots) {
        let viewModel = ProfileViewModel(repository: CorporaProfile("prof-x"), gallery: gallery, source: source)
        let snapshots = Snapshots()
        viewModel.onGalleryChange = { snapshots.all.append($0) }
        viewModel.viewDidLoad()
        return (viewModel, snapshots)
    }

    /// Someone else's Liked and Saved are the server's lists: a tab each,
    /// once they hold something.
    @Test func anotherProfilesLikedAndSavedAreTheServers() async {
        let gallery = CorporaGallery(liked: ["prof-x": [tile("l1"), tile("l2")]], saved: ["prof-x": [tile("s1")]])
        let (viewModel, snapshots) = await load(.profile(ProfileID("prof-x")), gallery: gallery)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(await settle {
            snapshots.last?.reactions == .content([tile("l1"), tile("l2")])
                && snapshots.last?.saved == .content([tile("s1")])
        })
    }

    /// A tab its owner hides comes back empty from the server: no tab.
    @Test func aHiddenTabIsEmpty() async {
        let gallery = CorporaGallery()
        let (viewModel, snapshots) = await load(.profile(ProfileID("prof-x")), gallery: gallery)
        _ = await settle { await gallery.likedAsks.count == 1 && !viewModel.isGalleryLoading }
        _ = await settle { snapshots.last?.activity != .loading }

        #expect(snapshots.last?.reactions == .empty(message: ""))
        #expect(snapshots.last?.saved == .empty(message: ""))
    }

    /// The viewer's own Liked is read too; their Saved is their pile, never
    /// asked of the server here.
    @Test func theViewersOwnLikedIsReadButNotTheirSaved() async {
        let gallery = CorporaGallery(liked: ["prof-x": [tile("l1")]], saved: ["prof-x": [tile("nope")]])
        let (viewModel, snapshots) = await load(.currentUser, gallery: gallery)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(await settle { snapshots.last?.reactions == .content([tile("l1")]) })
        #expect(await gallery.savedAsks.isEmpty)
        #expect(snapshots.last?.saved != .content([tile("nope")]))
    }

    /// A revisit inside the cache's freshness window asks for neither the
    /// header nor the grid — but Liked is kept nowhere, so it is read again.
    @Test func aFreshRevisitStillReadsTheLists() async {
        let cache = ProfileCache()
        let gallery = CorporaGallery(liked: ["prof-x": [tile("l1")]])
        let first = ProfileViewModel(
            repository: CorporaProfile("prof-x"), gallery: gallery, source: .profile(ProfileID("prof-x")), cache: cache
        )
        let firstSnapshots = Snapshots()
        first.onGalleryChange = { firstSnapshots.all.append($0) }
        first.viewDidLoad()
        #expect(await settle { firstSnapshots.last?.reactions == .content([tile("l1")]) && !first.isGalleryLoading })

        let second = ProfileViewModel(
            repository: CorporaProfile("prof-x"), gallery: gallery, source: .profile(ProfileID("prof-x")), cache: cache
        )
        let snapshots = Snapshots()
        second.onGalleryChange = { snapshots.all.append($0) }
        second.viewDidLoad()

        #expect(await settle { snapshots.last?.reactions == .content([tile("l1")]) })
        #expect(await gallery.likedAsks.count == 2)
        withExtendedLifetime(first) {}
    }

    /// A refresh reads the lists again: a tab its owner just hid goes.
    @Test func aRefreshReadsTheListsAgain() async {
        let gallery = CorporaGallery(saved: ["prof-x": [tile("s1")]])
        let (viewModel, snapshots) = await load(.profile(ProfileID("prof-x")), gallery: gallery)
        _ = await settle { snapshots.last?.saved == .content([tile("s1")]) }
        await gallery.setSaved([], for: "prof-x")

        viewModel.refresh()

        #expect(await settle { snapshots.last?.saved == .empty(message: "") })
    }
}

// MARK: - The mock and the repository

struct EngagementTabsRepositoryTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private struct MemberToken: AuthTokenProviding {
        func validAccessToken() async throws -> String? { "at-1" }
    }

    /// The Liked tab lists the posts the profile's account staked on, newest
    /// first; a visitor reads it only while its owner shows it.
    @Test func theLikedTabListsTheAccountsLikesWhileShown() async throws {
        let dataset = MockSocialDataset()
        let store = MockCounterStore(dataset: dataset)
        let other = try #require(dataset.authors.first { dataset.accountID(for: $0.profileID) != MockAuthService.accountID })
        let otherAccount = dataset.accountID(for: other.profileID)
        let posts = dataset.posts.prefix(3).map(\.postID)
        for post in posts { store.stake(1, account: otherAccount, target: "post:" + post) }
        store.stake(1, account: otherAccount, target: "post:" + posts[0]) // a second point: not a new like
        let flag = LockedFlag()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockLikesByProfileService(store: store, dataset: dataset, showsLikes: { _ in flag.value }).register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: MemberToken(), httpClient: bff
        )
        let gallery = ProfileGalleryRepository(
            postClient: Post_V1_PostServiceClient(client: client),
            searchClient: Search_V1_SearchServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client)
        )

        let liked = try await gallery.likedPosts(of: ProfileID(other.profileID))
        #expect(liked.map(\.id.rawValue) == posts.reversed())

        flag.value = false
        #expect(try await gallery.likedPosts(of: ProfileID(other.profileID)).isEmpty)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = true
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
