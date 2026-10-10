import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Profile

// MARK: - Fixtures

private func tile(
    _ id: String,
    kind: GalleryPost.Kind,
    isRepost: Bool = false,
    publishedAtMS: Int64 = 0
) -> GalleryPost {
    GalleryPost(
        id: PostID(id),
        kind: kind,
        isRepost: isRepost,
        thumbnailURL: nil,
        caption: "caption \(id)",
        publishedAtMS: publishedAtMS
    )
}

private let authored: [GalleryPost] = [
    tile("p-photo", kind: .photo, publishedAtMS: 60),
    tile("p-video", kind: .video, publishedAtMS: 50),
    tile("p-text", kind: .text, publishedAtMS: 40),
    tile("r-photo", kind: .photo, isRepost: true, publishedAtMS: 30),
    tile("r-video", kind: .video, isRepost: true, publishedAtMS: 20)
]

private let tagged: [GalleryPost] = [
    tile("t-photo", kind: .photo, publishedAtMS: 55),
    tile("t-text", kind: .text, publishedAtMS: 10)
]

/// Main-actor-isolated collector for values emitted on the main actor.
@MainActor
private final class Box<T> {
    private(set) var items: [T] = []
    func append(_ item: T) { items.append(item) }
}

/// Minimal happy-path profile source; gallery tests drive the grid, not the
/// header, so one canned profile suffices.
private actor StubProfileProvider: ProfileProviding {
    private let profile: UserProfile
    init(_ profile: UserProfile) { self.profile = profile }

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
    func changeHandle(_ newHandle: String) async throws -> UserProfile {
        profile
    }
}

private actor StubGalleryProvider: ProfileGalleryProviding {
    private let authored: [GalleryPost]
    private let tagged: [GalleryPost]
    private(set) var authoredCalls = 0
    private(set) var taggedCalls = 0
    private(set) var lastTaggedHandle: String?

    init(authored: [GalleryPost], tagged: [GalleryPost]) {
        self.authored = authored
        self.tagged = tagged
    }

    func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] {
        authoredCalls += 1
        return authored
    }

    func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] {
        taggedCalls += 1
        lastTaggedHandle = handle
        return tagged
    }


    func posts(ids: [String]) async throws -> [GalleryPost] { [] }
}

// MARK: - Filter semantics (pure)

struct GalleryFilterTests {
    @Test func defaultCombinationIsTheFullTimelineNewestFirst() {
        let result = GalleryFilter().tiles(authored: authored, tagged: tagged)
        // All sources merged and re-sorted chronologically (t-photo lands
        // between the authored posts by timestamp).
        #expect(result.map(\.id) == [
            PostID("p-photo"), PostID("t-photo"), PostID("p-video"),
            PostID("p-text"), PostID("r-photo"), PostID("r-video"), PostID("t-text")
        ])
    }

    @Test func mediaFormatDropsTextAcrossSources() {
        let filter = GalleryFilter(format: .media, source: .all)
        let result = filter.tiles(authored: authored, tagged: tagged)
        #expect(result.map(\.id) == [
            PostID("p-photo"), PostID("t-photo"), PostID("p-video"),
            PostID("r-photo"), PostID("r-video")
        ])
    }

    @Test func shortFormatKeepsOnlyText() {
        let filter = GalleryFilter(format: .short, source: .all)
        let result = filter.tiles(authored: authored, tagged: tagged)
        #expect(result.map(\.id) == [PostID("p-text"), PostID("t-text")])
    }

    @Test func repostsSourceSplitsOnLineage() {
        let filter = GalleryFilter(format: .media, source: .reposts)
        let result = filter.tiles(authored: authored, tagged: tagged)
        #expect(result.map(\.id) == [PostID("r-photo"), PostID("r-video")])
    }

    @Test func taggedSourceIgnoresAuthoredPosts() {
        let filter = GalleryFilter(format: .short, source: .tagged)
        let result = filter.tiles(authored: authored, tagged: tagged)
        #expect(result.map(\.id) == [PostID("t-text")])
    }

    @Test func postsSourceExcludesRepostsAndTagged() {
        let filter = GalleryFilter(format: .activity, source: .posts)
        let result = filter.tiles(authored: authored, tagged: tagged)
        #expect(result.map(\.id) == [PostID("p-photo"), PostID("p-video"), PostID("p-text")])
    }

    @Test func emptyCombinationYieldsNoTiles() {
        let filter = GalleryFilter(format: .short, source: .reposts)
        #expect(filter.tiles(authored: authored, tagged: tagged).isEmpty)
    }

    /// A FILTERED page says why it is narrower than the profile — that is the
    /// thing the tab itself cannot know.
    @Test func emptyMessagesNameTheCombination() {
        #expect(ProfileGalleryStore.emptyMessage(
            for: GalleryFilter(format: .media, source: .reposts)
        ) == "No media in reposts yet.")
        #expect(ProfileGalleryStore.emptyMessage(
            for: GalleryFilter(format: .short, source: .tagged)
        ) == "No short posts in tagged posts yet.")
    }

    /// ⚠️ And an UNFILTERED one says nothing, deliberately. The page is empty
    /// because the profile has nothing of that kind, which the tab's own empty
    /// state already says with a glyph and a headline — a generated sentence
    /// underneath it would be the same fact twice, in worse words.
    @Test(arguments: [GalleryFilter.Format.activity, .media, .short])
    func anUnfilteredPageLeavesTheTabToSpeak(format: GalleryFilter.Format) {
        #expect(ProfileGalleryStore.emptyMessage(
            for: GalleryFilter(format: format, source: .all)
        ).isEmpty)
    }
}

// MARK: - Metadata formatting (pure)

struct PostMetadataTests {
    @Test func countsAbbreviateLikeTheHeaderMetrics() {
        #expect(PostMetadata.count(0) == "0")
        #expect(PostMetadata.count(987) == "987")
        #expect(PostMetadata.count(1_234) == "1.2K")
        #expect(PostMetadata.count(2_000_000) == "2M")
    }

    @Test func compactAgeStepsThroughTheLadder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(secondsAgo: TimeInterval) -> String {
            PostMetadata.compactAge(
                ofMillis: Int64((now.timeIntervalSince1970 - secondsAgo) * 1000),
                now: now
            )
        }
        #expect(age(secondsAgo: 30) == "now")
        #expect(age(secondsAgo: 5 * 60) == "5m")
        #expect(age(secondsAgo: 3 * 3600) == "3h")
        #expect(age(secondsAgo: 2 * 86_400) == "2d")
        // A week and beyond falls back to a calendar date; exact wording is
        // locale-dependent, so assert the shape (contains a digit, no "d").
        let dated = age(secondsAgo: 30 * 86_400)
        #expect(dated.rangeOfCharacter(from: .decimalDigits) != nil)
        #expect(!dated.hasSuffix("d"))
    }
}

// MARK: - View-model gallery flows

@MainActor
struct ProfileGalleryViewModelTests {
    private func makeViewModel(
        gallery: StubGalleryProvider = StubGalleryProvider(authored: authored, tagged: tagged),
        source: ProfileViewModel.Source = .profile(ProfileID("prof-1"))
    ) -> (ProfileViewModel, () -> [ProfileViewModel.GallerySnapshot]) {
        let profile = UserProfile(
            id: ProfileID("prof-1"),
            handle: "ada",
            displayName: "Ada Lovelace",
            bio: "",
            avatarURL: nil,
            websiteURL: nil,
            isVerified: false,
            followerCount: .exact(1),
            followingCount: .exact(1),
            reactionCount: .unavailable
        )
        let viewModel = ProfileViewModel(
            repository: StubProfileProvider(profile),
            gallery: gallery,
            source: source
        )
        let box = Box<ProfileViewModel.GallerySnapshot>()
        viewModel.onGalleryChange = { box.append($0) }
        return (viewModel, { box.items })
    }

    /// Lets the view model's load chain finish.
    ///
    /// Polls rather than sleeping once: swift-testing runs suites in parallel,
    /// and a single fixed sleep is a wall-clock bet that a loaded machine
    /// loses — these tests went flaky the moment more suites were added to the
    /// package. `until` exits as soon as the state under test has arrived; the
    /// no-argument form spends the whole budget, which is still bounded.
    private func settle(until condition: @escaping () -> Bool = { false }) async {
        for _ in 0..<60 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func withoutProviderTheGalleryStaysHidden() async {
        let viewModel = ProfileViewModel(repository: StubProfileProvider(UserProfile(
            id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", bio: "",
            avatarURL: nil, websiteURL: nil, isVerified: false,
            followerCount: .exact(0), followingCount: .exact(0),
            reactionCount: .unavailable
        )))
        let box = Box<ProfileViewModel.GallerySnapshot>()
        viewModel.onGalleryChange = { box.append($0) }
        #expect(!viewModel.hasGallery)

        viewModel.viewDidLoad()
        await settle()

        #expect(box.items.isEmpty)
    }

    /// Your own Posts — its own posts, reposts and tags being their own pages
    /// since #772 — and the media its "View all" pushes (#631).
    @Test func landsWithPostsAndTheirMediaResolved() async {
        let gallery = StubGalleryProvider(authored: authored, tagged: tagged)
        let (viewModel, snapshots) = makeViewModel(gallery: gallery, source: .currentUser)

        viewModel.viewDidLoad()
        await settle()

        guard let snapshot = snapshots().last else {
            Issue.record("expected a snapshot")
            return
        }
        guard case .content(let activity) = snapshot.activity,
              case .content(let media) = snapshot.media else {
            Issue.record("expected content on both lists")
            return
        }
        #expect(activity.count == 3)
        #expect(activity.contains { $0.id == PostID("p-text") }, "text posts are cards in Posts")
        #expect(media.count == 2)
        #expect(snapshot.isComplete, "one page each: nothing more is coming")
        // Both corpora fetch eagerly (the pager shows neighbors mid-swipe),
        // with the mention query built from the loaded handle.
        #expect(await gallery.authoredCalls == 1)
        #expect(await gallery.taggedCalls == 1)
        #expect(await gallery.lastTaggedHandle == "ada")
    }

    /// ⚠️ YOUR OWN PROFILE'S PAGES ARE ITS SOURCES TOO (#772): Posts without
    /// reposts, Reposts, Tagged — what the bar's source menu used to narrow
    /// one list to — from the same two fetches, the media "View all" pushes
    /// following the page on screen.
    @Test func yourOwnPagesArePostsRepostsAndTagged() async throws {
        let gallery = StubGalleryProvider(authored: authored, tagged: tagged)
        let (viewModel, snapshots) = makeViewModel(gallery: gallery, source: .currentUser)
        viewModel.viewDidLoad()
        await settle { snapshots().last.map { $0.tagged != .loading && $0.activity != .loading } ?? false }
        let snapshot = try #require(snapshots().last)

        func ids(_ state: ProfileViewModel.GalleryPageState) -> [String] {
            guard case .content(let posts) = state else { return [] }
            return posts.map(\.id.rawValue)
        }
        #expect(ids(snapshot.activity) == ["p-photo", "p-video", "p-text"])
        #expect(ids(snapshot.reposts) == ["r-photo", "r-video"])
        #expect(ids(snapshot.tagged) == ["t-photo", "t-text"])
        #expect(ids(snapshot.media) == ["p-photo", "p-video"])
        viewModel.setActiveTab(.reposts)
        let onReposts = try #require(snapshots().last)
        #expect(ids(onReposts.media) == ["r-photo", "r-video"])
        // No refetch: the pages split the cached datasets.
        #expect(await gallery.authoredCalls == 1)
        #expect(await gallery.taggedCalls == 1)
    }

    /// ⚠️ AN ACCOUNT SWITCH LANDS ON POSTS (#772): the gallery starts over,
    /// only Posts shows while the sources reload, and the source goes back
    /// with it — a switch made on Tagged left Posts paging the tagged corpus.
    @Test func anAccountSwitchPutsTheSourceBackOnPosts() async throws {
        let gallery = StubGalleryProvider(authored: authored, tagged: tagged)
        let (viewModel, snapshots) = makeViewModel(gallery: gallery, source: .currentUser)
        viewModel.viewDidLoad()
        await settle { snapshots().last.map { $0.tagged != .loading } ?? false }
        viewModel.setActiveTab(.tagged)
        try #require(viewModel.gallerySource == .tagged, "guard: the page did not pick its source")

        viewModel.revalidate(after: nil)
        await settle { viewModel.gallerySource == .posts }

        #expect(viewModel.gallerySource == .posts)
    }

    /// SOMEONE ELSE'S PROFILE: three pages, three sources (#696). Posts is
    /// their own posts without reposts, Reposts only those, Tagged others'
    /// posts that mention them — from the same two fetches, and whatever the
    /// global source preference says.
    @Test func someoneElsesPagesArePostsRepostsAndTagged() async throws {
        let gallery = StubGalleryProvider(authored: authored, tagged: tagged)
        let (viewModel, snapshots) = makeViewModel(gallery: gallery)
        viewModel.viewDidLoad()
        await settle { snapshots().last.map { $0.tagged != .loading && $0.activity != .loading } ?? false }
        let snapshot = try #require(snapshots().last)

        func ids(_ state: ProfileViewModel.GalleryPageState) -> [String] {
            guard case .content(let posts) = state else { return [] }
            return posts.map(\.id.rawValue)
        }
        #expect(ids(snapshot.activity) == ["p-photo", "p-video", "p-text"])
        #expect(ids(snapshot.reposts) == ["r-photo", "r-video"])
        #expect(ids(snapshot.tagged) == ["t-photo", "t-text"])
        #expect(snapshot.isComplete && snapshot.repostsComplete && snapshot.taggedComplete)
        #expect(await gallery.authoredCalls == 1)
        #expect(await gallery.taggedCalls == 1)

        // "View all" pushes the page on screen's media.
        #expect(ids(snapshot.media) == ["p-photo", "p-video"])
        viewModel.setActiveTab(.reposts)
        let onReposts = try #require(snapshots().last)
        #expect(ids(onReposts.media) == ["r-photo", "r-video"])
        viewModel.setActiveTab(.tagged)
        let onTagged = try #require(snapshots().last)
        #expect(ids(onTagged.media) == ["t-photo"])
    }

    /// A page with nothing says so in its own words: the model leaves the
    /// tab's copy to speak.
    @Test func someoneElsesEmptyPagesLetTheirTabSpeak() async throws {
        let gallery = StubGalleryProvider(authored: authored.filter { !$0.isRepost }, tagged: [])
        let (viewModel, snapshots) = makeViewModel(gallery: gallery)
        viewModel.viewDidLoad()
        await settle { snapshots().last.map { $0.tagged != .loading } ?? false }
        let snapshot = try #require(snapshots().last)
        #expect(snapshot.reposts == .empty(message: ""))
        #expect(snapshot.tagged == .empty(message: ""))
        #expect(ProfileTab.reposts.emptyState.title == "No Reposts Yet")
        #expect(ProfileTab.tagged.emptyState.title == "No Tagged Posts")
    }

    @Test func formatSelectionIsPureStateWithNoFetch() async {
        let gallery = StubGalleryProvider(authored: authored, tagged: tagged)
        let (viewModel, snapshots) = makeViewModel(gallery: gallery)
        viewModel.viewDidLoad()
        await settle()
        let landed = snapshots().count

        viewModel.setGalleryFormat(.short)
        viewModel.setGalleryFormat(.media)
        await settle()

        #expect(viewModel.galleryFilter.format == .media)
        #expect(snapshots().count == landed) // pages unchanged — no re-emission
        #expect(await gallery.authoredCalls == 1)
        #expect(await gallery.taggedCalls == 1)
    }

    @Test func filterChoicesPersistGloballyAcrossViewModels() async {
        // An ephemeral suite: the GLOBAL preference without polluting the
        // test host's real defaults.
        let suiteName = "gallery-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GalleryPreferences(defaults: defaults)

        let first = ProfileViewModel(
            repository: StubProfileProvider(UserProfile(
                id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", bio: "",
                avatarURL: nil, websiteURL: nil, isVerified: false,
                followerCount: .exact(0), followingCount: .exact(0),
                reactionCount: .unavailable
            )),
            gallery: StubGalleryProvider(authored: authored, tagged: tagged),
            galleryPreferences: preferences
        )
        first.setGalleryFormat(.media)

        // A NEW view model (a newly opened profile) lands on the stored pair.
        let second = ProfileViewModel(
            repository: StubProfileProvider(UserProfile(
                id: ProfileID("prof-2"), handle: "grace", displayName: "Grace", bio: "",
                avatarURL: nil, websiteURL: nil, isVerified: false,
                followerCount: .exact(0), followingCount: .exact(0),
                reactionCount: .unavailable
            )),
            gallery: StubGalleryProvider(authored: authored, tagged: tagged),
            galleryPreferences: preferences
        )
        // ⚠️ THE FORMAT DOES NOT CARRY OVER (#631): the format named one of
        // three pages, and a profile opens on its one list, every post — a
        // stored Gallery would narrow it to media unseen. (No source either:
        // the menu that set one is gone, #772.)
        #expect(second.galleryFilter.format == .activity)
    }

    @Test func withoutAStoreTheFilterStaysSessionLocal() async {
        let (viewModel, _) = makeViewModel()
        viewModel.setGalleryFormat(.short)
        // A fresh preference-less view model starts at the default.
        let (another, _) = makeViewModel()
        #expect(another.galleryFilter == GalleryFilter())
    }

    @Test func refreshRefetchesBothCorpora() async {
        let gallery = StubGalleryProvider(authored: authored, tagged: tagged)
        let (viewModel, _) = makeViewModel(gallery: gallery)
        viewModel.viewDidLoad()
        await settle()

        viewModel.refresh()
        await settle()

        #expect(await gallery.authoredCalls == 2)
        #expect(await gallery.taggedCalls == 2)
    }
}
