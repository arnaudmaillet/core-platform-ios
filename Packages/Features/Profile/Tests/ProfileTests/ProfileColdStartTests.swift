import AuthInterface
import CacheKit
import CoreModels
import CoreNetworking
import Foundation
import LocalStore
import PostGrid
import Synchronization
import Testing
@testable import Profile

// The viewer's own profile and the profiles they visited open on their last
// content at a cold start, from the LocalStore (#893).

private final class StoreFolder: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ProfileColdStartTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: url) }
}

private final class ViewerBox: Sendable {
    private let current = Mutex<LocalStoreViewer?>(.member(account: "acct-1", profile: "me"))

    var viewer: LocalStoreViewer? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

private func tile(_ id: String, at ms: Int64) -> GalleryPost {
    var post = GalleryPost(
        id: PostID(id), kind: .video, isRepost: false,
        pages: [
            GalleryPost.MediaPage(thumbnailURL: URL(string: "https://cdn.example/\(id).jpg"), videoURL: URL(string: "https://cdn.example/\(id).mp4"), aspectRatio: 0.5625),
            GalleryPost.MediaPage(thumbnailURL: nil, aspectRatio: 1)
        ],
        caption: "caption \(id)", publishedAtMS: ms,
        authorID: ProfileID("prof-1"), authorName: "Ada", authorHandle: "ada",
        authorAvatarURL: URL(string: "https://cdn.example/ada.jpg"), reactionCount: 12, commentCount: 0
    )
    post.likeCountsHidden = true
    return post
}

private func person(_ id: String, visibility: ProfileVisibility = .public) -> UserProfile {
    UserProfile(
        id: ProfileID(id), handle: "h-\(id)", displayName: "Name \(id)", bio: "bio \(id)",
        avatarURL: URL(string: "https://cdn.example/\(id).jpg"), websiteURL: URL(string: "https://example.com"),
        customLinks: [ProfileLink(label: "Shop", url: "https://shop.example")],
        isVerified: true, visibility: visibility,
        followerCount: .exact(12), followingCount: .atLeast(500), reactionCount: .unavailable,
        accountType: .business, businessCategory: "Bakery"
    )
}

private actor ColdGallery: ProfileGalleryProviding {
    private let pages: [String?: GalleryPage]
    private var offline = false

    init(pages: [String?: GalleryPage]) { self.pages = pages }

    func goOffline() { offline = true }

    /// First pages asked for (a load or a revalidation of the grid).
    private(set) var firstPageFetches = 0

    func authoredPage(for profileID: ProfileID, after pageToken: String?) async throws -> GalleryPage {
        if pageToken == nil { firstPageFetches += 1 }
        if offline { throw URLError(.notConnectedToInternet) }
        return pages[pageToken] ?? GalleryPage(posts: [], nextPageToken: nil)
    }
    func taggedPage(for profileID: ProfileID, handle: String, after pageToken: String?) async throws -> GalleryPage {
        if offline { throw URLError(.notConnectedToInternet) }
        return GalleryPage(posts: [], nextPageToken: nil)
    }
    func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
    func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
    func posts(ids: [String]) async throws -> [GalleryPost] { [] }
}

private actor ColdProfiles: ProfileProviding {
    let own: UserProfile
    let other: UserProfile
    let answer: ProfileRelationship
    private var offline = false

    init(own: UserProfile = person("me"), other: UserProfile = person("prof-1"), relationship: ProfileRelationship = .other(isFollowing: true, isBlocked: false)) {
        self.own = own
        self.other = other
        answer = relationship
    }

    func goOffline() { offline = true }

    private func check() throws {
        if offline { throw URLError(.notConnectedToInternet) }
    }

    /// Profile reads asked for, offline ones included.
    private(set) var profileFetches = 0
    private(set) var relationshipReads = 0

    func currentUserProfile() async throws -> UserProfile { profileFetches += 1; try check(); return own }
    func profile(id: ProfileID) async throws -> UserProfile { profileFetches += 1; try check(); return other }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
        relationshipReads += 1
        try check()
        return answer
    }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile { own }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { own }
}

@MainActor
final class ProfileColdStartTests {
    private let folder = StoreFolder()
    private let viewer = ViewerBox()
    private let center = NotificationCenter()

    @MainActor
    private final class Shown {
        var snapshots: [ProfileViewModel.GallerySnapshot] = []
        var phases: [ProfileViewModel.Phase] = []
        var buttons: [ProfileViewModel.FollowButton] = []
    }

    /// One launch's cache, over a new store on the same file. `later`: how
    /// long after the previous session it launches, as its clock sees it.
    private func launchCache(later: TimeInterval = 0) throws -> ProfileCache {
        let box = viewer
        return ProfileCache(
            center: center, store: try LocalStore(directory: folder.url, viewer: { box.viewer }),
            now: { Date().addingTimeInterval(later) }
        )
    }

    /// A launch past the profile screen's freshness window: it revalidates.
    private func staleLaunchCache() throws -> ProfileCache {
        try launchCache(later: LocalStorePolicy.profileScreenRevalidation + 60)
    }

    private func gallery() -> ColdGallery {
        ColdGallery(pages: [
            nil: GalleryPage(posts: [tile("a", at: 60), tile("b", at: 50)], nextPageToken: "p2"),
            "p2": GalleryPage(posts: [tile("c", at: 40)], nextPageToken: nil)
        ])
    }

    private func open(
        _ source: ProfileViewModel.Source, cache: ProfileCache, profiles: ColdProfiles, gallery: ColdGallery
    ) -> (ProfileViewModel, Shown) {
        let viewModel = ProfileViewModel(repository: profiles, gallery: gallery, source: source, cache: cache)
        let shown = Shown()
        viewModel.onGalleryChange = { shown.snapshots.append($0) }
        viewModel.onPhaseChange = { shown.phases.append($0) }
        viewModel.onFollowButtonChange = { shown.buttons.append($0) }
        // Its own monitor: the shared one is process-wide.
        viewModel.connectivity = ConnectivityMonitor(offlineGrace: 0)
        viewModel.viewDidLoad()
        return (viewModel, shown)
    }

    @discardableResult
    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func ids(_ state: ProfileViewModel.GalleryPageState?) -> [String] {
        guard case .content(let posts) = state else { return [] }
        return posts.map(\.id.rawValue)
    }

    private func isContent(_ phase: ProfileViewModel.Phase?) -> Bool {
        if case .content? = phase { return true }
        return false
    }

    /// The previous session: `source` opened online, its two pages loaded.
    private func previousSession(_ source: ProfileViewModel.Source) async throws {
        let cache = try launchCache()
        let (viewModel, shown) = open(source, cache: cache, profiles: ColdProfiles(), gallery: gallery())
        try #require(await settle { ids(shown.snapshots.last?.activity) == ["a", "b"] })
        viewModel.loadMoreGallery()
        try #require(await settle { ids(shown.snapshots.last?.activity) == ["a", "b", "c"] })
        try #require(await settle { shown.buttons.last.map { $0 != .hidden } ?? false })
        cache.waitForDeviceWrites()
    }

    @Test func aRecordRoundTripsEveryField() throws {
        let corpora = ProfileGalleryStore.Corpora(
            authored: ProfileGalleryStore.Corpus(posts: [tile("a", at: 1), tile("b", at: 2)], nextToken: "t", hasLaterPages: true),
            tagged: ProfileGalleryStore.Corpus(posts: [], nextToken: nil, hasLaterPages: false)
        )
        let record = ProfileDiskRecord(
            profile: ProfileDiskRecord.Header(person("prof-1", visibility: .private)),
            relationship: nil,
            gallery: ProfileDiskRecord.Gallery(corpora)
        )
        let decoded = try JSONDecoder().decode(ProfileDiskRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.profile?.userProfile == person("prof-1", visibility: .private))
        #expect(decoded.gallery?.corpora == corpora)
        let relationships: [ProfileRelationship] = [
            .me, .requested, .cannotFollow, .other(isFollowing: true, isMutual: true, isBlocked: false),
            .other(isFollowing: false, isBlocked: true)
        ]
        for relationship in relationships {
            #expect(ProfileDiskRecord.Relationship(relationship).relationship == relationship)
        }
    }

    @Test func aVisitedProfileOpensOnItsLastContentAfterAColdStart() async throws {
        try await previousSession(.profile(ProfileID("prof-1")))

        let profiles = ColdProfiles()
        await profiles.goOffline()
        let offlineGallery = gallery()
        await offlineGallery.goOffline()
        let (viewModel, shown) = open(.profile(ProfileID("prof-1")), cache: try staleLaunchCache(), profiles: profiles, gallery: offlineGallery)

        // Before any await: the header, the button and the pages.
        #expect(isContent(shown.phases.last))
        #expect(viewModel.profile == person("prof-1"))
        #expect(shown.buttons.last == .following)
        #expect(ids(shown.snapshots.first?.activity) == ["a", "b", "c"], "the cold start opened on bones")
        // Offline, the revalidation fails and the content stays.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(isContent(shown.phases.last))
        #expect(ids(shown.snapshots.last?.activity) == ["a", "b", "c"])
    }

    @Test func theViewersOwnProfileOpensOnItsLastContentOffline() async throws {
        try await previousSession(.currentUser)

        let profiles = ColdProfiles()
        await profiles.goOffline()
        let offlineGallery = gallery()
        await offlineGallery.goOffline()
        let cache = try staleLaunchCache()
        #expect(cache.currentUserID() == ProfileID("me"))
        let (viewModel, shown) = open(.currentUser, cache: cache, profiles: profiles, gallery: offlineGallery)

        #expect(isContent(shown.phases.last), "the network cannot say who the viewer is: the device does")
        #expect(viewModel.profile == person("me"))
        #expect(ids(shown.snapshots.first?.activity) == ["a", "b", "c"])
        try? await Task.sleep(for: .milliseconds(150))
        #expect(isContent(shown.phases.last))
        withExtendedLifetime(viewModel) {}
    }

    @Test func aOnePageGalleryStaysWhenTheOfflineRevalidationFails() async throws {
        // The viewer's own profile, whose posts fit one page.
        let onePage = ColdGallery(pages: [nil: GalleryPage(posts: [tile("a", at: 60), tile("b", at: 50)], nextPageToken: nil)])
        do {
            let cache = try launchCache()
            let (session, shown) = open(.currentUser, cache: cache, profiles: ColdProfiles(), gallery: onePage)
            try #require(await settle { ids(shown.snapshots.last?.activity) == ["a", "b"] })
            cache.waitForDeviceWrites()
            withExtendedLifetime(session) {}
        }
        let profiles = ColdProfiles()
        await profiles.goOffline()
        await onePage.goOffline()
        let (viewModel, shown) = open(.currentUser, cache: try staleLaunchCache(), profiles: profiles, gallery: onePage)
        #expect(ids(shown.snapshots.first?.activity) == ["a", "b"])
        try? await Task.sleep(for: .milliseconds(150))
        #expect(ids(shown.snapshots.last?.activity) == ["a", "b"], "the failed revalidation blanked the grid")
        withExtendedLifetime(viewModel) {}
    }

    @Test func anotherViewerOpensOnBones() async throws {
        try await previousSession(.profile(ProfileID("prof-1")))

        viewer.viewer = .member(account: "acct-2", profile: "prof-9")
        let cache = try launchCache()
        #expect(cache.profile(for: ProfileID("prof-1")) == nil)
        #expect(cache.gallery(for: ProfileID("prof-1")) == nil)
        #expect(cache.currentUserID() == nil)
    }

    @Test func aFollowChangeOnAPrivateProfileDropsItsDeviceGalleryToo() async throws {
        let id = ProfileID("prof-1")
        do {
            let cache = try launchCache()
            cache.store(person("prof-1", visibility: .private))
            cache.store(.other(isFollowing: true, isBlocked: false), for: id)
            cache.store(ProfileGalleryStore.Corpora(
                authored: ProfileGalleryStore.Corpus(posts: [tile("a", at: 1)], nextToken: nil, hasLaterPages: false), tagged: nil
            ), for: id)
            cache.waitForDeviceWrites()
        }
        // The next session hears an unfollow before visiting the profile.
        let cache = try launchCache()
        cache.store(.other(isFollowing: false, isBlocked: false), for: id)
        cache.waitForDeviceWrites()
        #expect(cache.gallery(for: id) == nil)
        #expect(try launchCache().gallery(for: id) == nil, "the device copy no longer holds the posts")
        #expect(try launchCache().relationship(for: id) == .other(isFollowing: false, isBlocked: false))
    }

    // MARK: - Freshness (#893)

    /// What a test moves the cache's clock with.
    private final class Clock {
        var offset: TimeInterval = 0
        var now: Date { Date().addingTimeInterval(offset) }
    }

    /// A first visit online, on `cache`, settled: header, button, grid.
    private func firstVisit(cache: ProfileCache, profiles: ColdProfiles, gallery: ColdGallery) async throws -> ProfileViewModel {
        let (viewModel, shown) = open(.profile(ProfileID("prof-1")), cache: cache, profiles: profiles, gallery: gallery)
        try #require(await settle { ids(shown.snapshots.last?.activity) == ["a", "b"] })
        try #require(await settle { shown.buttons.last == .following })
        return viewModel
    }

    @Test func aProfileSeenSecondsAgoIsNotRefetchedOnARevisit() async throws {
        let clock = Clock()
        let cache = ProfileCache(center: center, now: { clock.now })
        let profiles = ColdProfiles()
        let pages = gallery()
        let first = try await firstVisit(cache: cache, profiles: profiles, gallery: pages)
        try #require(await profiles.profileFetches == 1)
        try #require(await pages.firstPageFetches == 1)

        clock.offset = 30
        let (revisit, shown) = open(.profile(ProfileID("prof-1")), cache: cache, profiles: profiles, gallery: pages)
        #expect(isContent(shown.phases.last))
        #expect(ids(shown.snapshots.last?.activity) == ["a", "b"])
        // The relationship is still read; the header and the grid are not.
        #expect(await settle { await profiles.relationshipReads == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await profiles.profileFetches == 1, "a profile fetched 30 s ago was fetched again")
        #expect(await pages.firstPageFetches == 1, "a grid fetched 30 s ago was fetched again")
        #expect(shown.buttons.last == .following)
        withExtendedLifetime((first, revisit)) {}
    }

    @Test func aRevisitPastTheWindowRevalidates() async throws {
        let clock = Clock()
        let cache = ProfileCache(center: center, now: { clock.now })
        let profiles = ColdProfiles()
        let pages = gallery()
        let first = try await firstVisit(cache: cache, profiles: profiles, gallery: pages)

        clock.offset = LocalStorePolicy.profileScreenRevalidation + 1
        let (revisit, shown) = open(.profile(ProfileID("prof-1")), cache: cache, profiles: profiles, gallery: pages)
        #expect(isContent(shown.phases.last), "a stale revisit still opens on the cached profile")
        #expect(await settle { await profiles.profileFetches == 2 })
        #expect(await settle { await pages.firstPageFetches == 2 })
        withExtendedLifetime((first, revisit)) {}
    }

    @Test func pullToRefreshRefetchesInsideTheWindow() async throws {
        let clock = Clock()
        let cache = ProfileCache(center: center, now: { clock.now })
        let profiles = ColdProfiles()
        let pages = gallery()
        let first = try await firstVisit(cache: cache, profiles: profiles, gallery: pages)

        clock.offset = 5
        let (revisit, _) = open(.profile(ProfileID("prof-1")), cache: cache, profiles: profiles, gallery: pages)
        revisit.refresh()
        #expect(await settle { await profiles.profileFetches == 2 }, "pull-to-refresh skipped the network")
        #expect(await settle { await pages.firstPageFetches == 2 })
        withExtendedLifetime((first, revisit)) {}
    }

    @Test func aColdStartInsideTheWindowSkipsTheFetchToo() async throws {
        try await previousSession(.profile(ProfileID("prof-1")))

        let profiles = ColdProfiles()
        let pages = gallery()
        let (viewModel, shown) = open(.profile(ProfileID("prof-1")), cache: try launchCache(later: 20), profiles: profiles, gallery: pages)
        #expect(isContent(shown.phases.last))
        #expect(ids(shown.snapshots.first?.activity) == ["a", "b", "c"])
        #expect(await settle { await profiles.relationshipReads == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await profiles.profileFetches == 0, "the device's fetch time did not survive the relaunch")
        #expect(await pages.firstPageFetches == 0)
        // And paging goes on from where the stored grid stops.
        #expect(await viewModel.galleryPostIDs(after: PostID("a")) == [PostID("b"), PostID("c")])
        withExtendedLifetime(viewModel) {}
    }

    @Test func aRevisitMissingACorpusRevalidates() async throws {
        let cache = ProfileCache(center: center)
        let id = ProfileID("prof-1")
        cache.store(person("prof-1"))
        // Only the authored posts are known: the tagged ones never loaded.
        cache.store(ProfileGalleryStore.Corpora(
            authored: ProfileGalleryStore.Corpus(posts: [tile("a", at: 1)], nextToken: nil, hasLaterPages: false), tagged: nil
        ), for: id)
        #expect(!cache.isFresh(id))
        let profiles = ColdProfiles()
        let (viewModel, _) = open(.profile(id), cache: cache, profiles: profiles, gallery: gallery())
        #expect(await settle { await profiles.profileFetches == 1 })
        withExtendedLifetime(viewModel) {}
    }
}
