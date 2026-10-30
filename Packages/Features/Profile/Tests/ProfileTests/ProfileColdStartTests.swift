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
    return post
}

private func person(_ id: String, visibility: ProfileVisibility = .public) -> UserProfile {
    UserProfile(
        id: ProfileID(id), handle: "h-\(id)", displayName: "Name \(id)", bio: "bio \(id)",
        avatarURL: URL(string: "https://cdn.example/\(id).jpg"), websiteURL: URL(string: "https://example.com"),
        customLinks: [ProfileLink(label: "Shop", url: "https://shop.example")],
        isVerified: true, visibility: visibility,
        followerCount: .exact(12), followingCount: .atLeast(500), reactionCount: .unavailable,
        accountType: .business, businessCategory: "Bakery", avatarFrameID: "frame.neon"
    )
}

private actor ColdGallery: ProfileGalleryProviding {
    private let pages: [String?: GalleryPage]
    private var offline = false
    private var isHeld = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// The Liked tab's posts (#1776).
    private let liked: [GalleryPost]

    init(pages: [String?: GalleryPage], liked: [GalleryPost] = []) {
        self.pages = pages
        self.liked = liked
    }

    func goOffline() { offline = true }

    func likedPosts(of profileID: ProfileID) async throws -> [GalleryPost] {
        if offline { throw URLError(.notConnectedToInternet) }
        return liked
    }

    /// Holds every later first-page fetch until `release()`: the test decides
    /// which of the header and the grid answers first (#1091).
    func hold() { isHeld = true }

    func release() {
        isHeld = false
        held.forEach { $0.resume() }
        held = []
    }

    /// First pages asked for (a load or a revalidation of the grid).
    private(set) var firstPageFetches = 0

    func authoredPage(for profileID: ProfileID, after pageToken: String?) async throws -> GalleryPage {
        if pageToken == nil {
            firstPageFetches += 1
            if isHeld { await withCheckedContinuation { held.append($0) } }
        }
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

    private var isHeld = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// Holds every later profile read until `release()`: the test decides
    /// which of the header and the grid answers first (#1091).
    func hold() { isHeld = true }

    func release() {
        isHeld = false
        held.forEach { $0.resume() }
        held = []
    }

    private func gate() async {
        if isHeld { await withCheckedContinuation { held.append($0) } }
    }

    /// Profile reads asked for, offline ones included.
    private(set) var profileFetches = 0
    private(set) var relationshipReads = 0

    func currentUserProfile() async throws -> UserProfile { profileFetches += 1; await gate(); try check(); return own }
    func profile(id: ProfileID) async throws -> UserProfile { profileFetches += 1; await gate(); try check(); return other }
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

    /// The instant every launch's clock counts from. Fixed, never `Date()`
    /// read again: a clock that follows the wall moves while a starved runner
    /// stalls, and a "20 s later" launch becomes 60 s later (#1042).
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// One launch's cache, over a new store on the same file. `later`: how
    /// long after the previous session it launches, as its clock sees it.
    private func launchCache(later: TimeInterval = 0) throws -> ProfileCache {
        let box = viewer
        let launchedAt = epoch.addingTimeInterval(later)
        return ProfileCache(
            center: center, store: try LocalStore(directory: folder.url, viewer: { box.viewer }),
            now: { launchedAt }
        )
    }

    /// A launch past the profile screen's freshness window: it revalidates.
    private func staleLaunchCache() throws -> ProfileCache {
        try launchCache(later: LocalStorePolicy.profileScreenRevalidation + 60)
    }

    private func gallery(liked: [GalleryPost] = []) -> ColdGallery {
        ColdGallery(pages: [
            nil: GalleryPage(posts: [tile("a", at: 60), tile("b", at: 50)], nextPageToken: "p2"),
            "p2": GalleryPage(posts: [tile("c", at: 40)], nextPageToken: nil)
        ], liked: liked)
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

    /// A look budget, 6,000 × 10 ms like the other suites' (#1031): a smaller
    /// one ran out on a loaded CI runner before a revalidation's fetch landed.
    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
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
            tagged: ProfileGalleryStore.Corpus(posts: [], nextToken: nil, hasLaterPages: false),
            liked: [tile("l", at: 3)]
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

    /// A header stored before the avatar frame (#943) decodes with none.
    @Test func aHeaderStoredBeforeTheFrameDecodesWithNone() throws {
        let header = ProfileDiskRecord.Header(person("prof-1"))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(header)) as? [String: Any])
        json.removeValue(forKey: "avatarFrameID")
        let decoded = try JSONDecoder().decode(
            ProfileDiskRecord.Header.self, from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.userProfile.avatarFrameID == nil)
        #expect(header.userProfile.avatarFrameID == "frame.neon")
    }

    /// ⚠️ THE BANNER SURVIVES A COLD START (#1859): it was left out of the
    /// disk header, so a profile read back from disk had none until the
    /// network answered — the header collapsed, then grew again.
    @Test func theBannerRoundTripsThroughTheDisk() throws {
        let base = person("prof-1")
        let banner = URL(string: "https://example.test/banner.jpg")!
        let loop = URL(string: "https://example.test/banner.m3u8")!
        let profile = UserProfile(
            id: base.id, handle: base.handle, displayName: base.displayName, bio: base.bio,
            avatarURL: base.avatarURL, bannerURL: banner, bannerVideoURL: loop, websiteURL: base.websiteURL,
            isVerified: base.isVerified, followerCount: base.followerCount,
            followingCount: base.followingCount, reactionCount: base.reactionCount
        )
        let decoded = try JSONDecoder().decode(
            ProfileDiskRecord.Header.self, from: JSONEncoder().encode(ProfileDiskRecord.Header(profile))
        )
        #expect(decoded.userProfile.bannerURL == banner)
        #expect(decoded.userProfile.bannerVideoURL == loop)

        // A header stored before the banner decodes with none.
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ProfileDiskRecord.Header(profile))) as? [String: Any]
        )
        json.removeValue(forKey: "bannerURL")
        json.removeValue(forKey: "bannerVideoURL")
        let old = try JSONDecoder().decode(ProfileDiskRecord.Header.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.userProfile.bannerURL == nil)
        #expect(old.userProfile.handle == base.handle)
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

    /// The Liked tab opens with the grid at the next launch (#1776), instead
    /// of popping in once its read lands.
    @Test func theLikedTabOpensWithTheGridAfterAColdStart() async throws {
        let cache = try launchCache()
        let liked = [tile("l1", at: 70), tile("l2", at: 65)]
        let (first, shownFirst) = open(.currentUser, cache: cache, profiles: ColdProfiles(), gallery: gallery(liked: liked))
        // ⚠️ THE LIKES AND THE FIRST PAGE, NOT THE LIKES ALONE (#1952). The
        // cache keeps a gallery only once its posts (or tagged) are in
        // (`ProfileGalleryStore.corpora`): likes landing first are on screen
        // and in no write yet. Waited on alone, a slow runner flushed nothing
        // and the cold start read no likes.
        try #require(await settle {
            ids(shownFirst.snapshots.last?.reactions) == ["l1", "l2"]
                && !ids(shownFirst.snapshots.last?.activity).isEmpty
        })
        cache.waitForDeviceWrites()
        withExtendedLifetime(first) {}

        let profiles = ColdProfiles()
        await profiles.goOffline()
        let offlineGallery = gallery(liked: liked)
        await offlineGallery.goOffline()
        let (viewModel, shown) = open(.currentUser, cache: try staleLaunchCache(), profiles: profiles, gallery: offlineGallery)
        #expect(ids(shown.snapshots.first?.reactions) == ["l1", "l2"], "the Liked tab popped in after the grid")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(ids(shown.snapshots.last?.reactions) == ["l1", "l2"], "a failed read took the likes back")
        withExtendedLifetime(viewModel) {}
    }

    /// A Liked list the server now answers empty is not kept from before.
    @Test func anEmptiedLikedTabIsNotKept() throws {
        let cache = try launchCache()
        let id = ProfileID("me")
        let grid = ProfileGalleryStore.Corpus(posts: [tile("a", at: 1)], nextToken: nil, hasLaterPages: false)
        cache.store(ProfileGalleryStore.Corpora(authored: grid, tagged: nil, liked: [tile("l", at: 2)]), for: id)
        cache.store(ProfileGalleryStore.Corpora(authored: grid, tagged: nil, liked: nil), for: id)
        #expect(cache.gallery(for: id)?.liked == nil)
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

    /// What a test moves the cache's clock with. It moves only when the test
    /// says so, never with the wall: the ages below are exact under any load.
    private final class Clock {
        var offset: TimeInterval = 0
        var now: Date { Date(timeIntervalSinceReferenceDate: 800_000_000).addingTimeInterval(offset) }
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

    /// The grace that stands for "nothing more happens": a second grid fetch
    /// would have gone out at once, on the header's landing (#1091).
    private static let nothingMore = Duration.milliseconds(200)

    /// A revisit `open`ed with `onLoadSettled` watched: set before any await,
    /// so the header's load cannot settle unseen.
    private final class Settled {
        var isSettled = false
    }

    private func watchLoad(_ viewModel: ProfileViewModel) -> Settled {
        let settled = Settled()
        viewModel.onLoadSettled = { settled.isSettled = true }
        return settled
    }

    @Test func aRevisitPastTheWindowRevalidates() async throws {
        let clock = Clock()
        let cache = ProfileCache(center: center, now: { clock.now })
        let profiles = ColdProfiles()
        let pages = gallery()
        let first = try await firstVisit(cache: cache, profiles: profiles, gallery: pages)

        clock.offset = LocalStorePolicy.profileScreenRevalidation + 1
        let (revisit, shown) = open(.profile(ProfileID("prof-1")), cache: cache, profiles: profiles, gallery: pages)
        let header = watchLoad(revisit)
        #expect(isContent(shown.phases.last), "a stale revisit still opens on the cached profile")
        // Reached, then exact once both loads settled: an overshoot fails here
        // instead of running a budget out on `== 2` (#1091).
        #expect(await settle { await profiles.profileFetches >= 2 })
        #expect(await settle { await pages.firstPageFetches >= 2 })
        #expect(await settle { header.isSettled && !revisit.isGalleryLoading })
        #expect(await profiles.profileFetches == 2)
        #expect(await pages.firstPageFetches == 2, "a stale revisit fetched the grid more than once")
        try? await Task.sleep(for: Self.nothingMore) // nothing more happens
        #expect(await pages.firstPageFetches == 2, "a second grid fetch went out after both loads settled")
        withExtendedLifetime((first, revisit)) {}
    }

    /// ⚠️ THE ORDER THAT FETCHED THE GRID TWICE (#1091). The seed's grid
    /// revalidation answers before the header; the header's landing then
    /// found no grid load in flight and started a second one.
    @Test func aStaleRevisitWhoseGridAnswersFirstFetchesTheGridOnce() async throws {
        let clock = Clock()
        let cache = ProfileCache(center: center, now: { clock.now })
        let profiles = ColdProfiles()
        let pages = gallery()
        let first = try await firstVisit(cache: cache, profiles: profiles, gallery: pages)

        clock.offset = LocalStorePolicy.profileScreenRevalidation + 1
        await profiles.hold()
        let (revisit, _) = open(.profile(ProfileID("prof-1")), cache: cache, profiles: profiles, gallery: pages)
        let header = watchLoad(revisit)
        #expect(await settle { await pages.firstPageFetches == 2 }, "the seed did not revalidate the grid")
        #expect(await settle { !revisit.isGalleryLoading }, "the grid did not land while the header was held")
        #expect(await settle { await profiles.profileFetches == 2 })
        #expect(!header.isSettled, "guard: the header is still held")

        await profiles.release()
        #expect(await settle { header.isSettled })
        try? await Task.sleep(for: Self.nothingMore) // nothing more happens
        #expect(await pages.firstPageFetches == 2, "the header's landing fetched the grid a second time")
        #expect(!revisit.isGalleryLoading)
        withExtendedLifetime((first, revisit)) {}
    }

    /// The order that always worked: the header lands while the seed's grid
    /// revalidation is still out, and rides it.
    @Test func aStaleRevisitWhoseHeaderAnswersFirstFetchesTheGridOnce() async throws {
        let clock = Clock()
        let cache = ProfileCache(center: center, now: { clock.now })
        let profiles = ColdProfiles()
        let pages = gallery()
        let first = try await firstVisit(cache: cache, profiles: profiles, gallery: pages)

        clock.offset = LocalStorePolicy.profileScreenRevalidation + 1
        await pages.hold()
        let (revisit, _) = open(.profile(ProfileID("prof-1")), cache: cache, profiles: profiles, gallery: pages)
        let header = watchLoad(revisit)
        #expect(await settle { header.isSettled }, "the header did not land while the grid was held")
        #expect(await profiles.profileFetches == 2)
        #expect(await pages.firstPageFetches == 2)
        #expect(revisit.isGalleryLoading, "guard: the seed's grid revalidation is still out")

        await pages.release()
        #expect(await settle { !revisit.isGalleryLoading })
        try? await Task.sleep(for: Self.nothingMore) // nothing more happens
        #expect(await pages.firstPageFetches == 2, "a stale revisit fetched the grid more than once")
        withExtendedLifetime((first, revisit)) {}
    }

    /// A seed whose grid revalidation FAILED is tried again when the header
    /// lands: skipping the second fetch is only right when the first one
    /// answered.
    @Test func aStaleRevisitRetriesAGridRevalidationThatFailed() async throws {
        let clock = Clock()
        let cache = ProfileCache(center: center, now: { clock.now })
        let profiles = ColdProfiles()
        let pages = gallery()
        let first = try await firstVisit(cache: cache, profiles: profiles, gallery: pages)

        clock.offset = LocalStorePolicy.profileScreenRevalidation + 1
        let failing = gallery()
        await failing.goOffline()
        await profiles.hold()
        let (revisit, _) = open(.profile(ProfileID("prof-1")), cache: cache, profiles: profiles, gallery: failing)
        let header = watchLoad(revisit)
        #expect(await settle { await failing.firstPageFetches == 1 })
        #expect(await settle { !revisit.isGalleryLoading }, "the failed grid revalidation did not end")

        await profiles.release()
        #expect(await settle { header.isSettled })
        #expect(await settle { await failing.firstPageFetches == 2 }, "a failed grid revalidation was not tried again")
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
