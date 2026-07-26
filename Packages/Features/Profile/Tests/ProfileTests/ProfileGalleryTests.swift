import CoreModels
import Foundation
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

    @Test func emptyMessagesNameTheCombination() {
        #expect(ProfileViewModel.emptyMessage(
            for: GalleryFilter(format: .media, source: .reposts)
        ) == "No media in reposts yet.")
        #expect(ProfileViewModel.emptyMessage(
            for: GalleryFilter(format: .short, source: .all)
        ) == "No short posts yet.")
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
        gallery: StubGalleryProvider = StubGalleryProvider(authored: authored, tagged: tagged)
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
            reactionCount: .unavailable,
            viewCount: .unavailable
        )
        let viewModel = ProfileViewModel(
            repository: StubProfileProvider(profile),
            gallery: gallery,
            source: .profile(ProfileID("prof-1"))
        )
        let box = Box<ProfileViewModel.GallerySnapshot>()
        viewModel.onGalleryChange = { box.append($0) }
        return (viewModel, { box.items })
    }

    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func withoutProviderTheGalleryStaysHidden() async {
        let viewModel = ProfileViewModel(repository: StubProfileProvider(UserProfile(
            id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", bio: "",
            avatarURL: nil, websiteURL: nil, isVerified: false,
            followerCount: .exact(0), followingCount: .exact(0),
            reactionCount: .unavailable, viewCount: .unavailable
        )))
        let box = Box<ProfileViewModel.GallerySnapshot>()
        viewModel.onGalleryChange = { box.append($0) }
        #expect(!viewModel.hasGallery)

        viewModel.viewDidLoad()
        await settle()

        #expect(box.items.isEmpty)
    }

    @Test func landsWithAllThreeFormatPagesResolved() async {
        let gallery = StubGalleryProvider(authored: authored, tagged: tagged)
        let (viewModel, snapshots) = makeViewModel(gallery: gallery)

        viewModel.viewDidLoad()
        await settle()

        guard let snapshot = snapshots().last else {
            Issue.record("expected a snapshot")
            return
        }
        // Default source = All: every page carries the merged timeline slice.
        guard case .content(let activity) = snapshot.activity,
              case .content(let media) = snapshot.media,
              case .content(let short) = snapshot.short else {
            Issue.record("expected content on all pages")
            return
        }
        #expect(activity.count == 7)
        #expect(media.count == 5)
        #expect(short.map(\.id) == [PostID("p-text"), PostID("t-text")])
        // Both corpora fetch eagerly (the pager shows neighbors mid-swipe),
        // with the mention query built from the loaded handle.
        #expect(await gallery.authoredCalls == 1)
        #expect(await gallery.taggedCalls == 1)
        #expect(await gallery.lastTaggedHandle == "ada")
    }

    @Test func sourceModifierRecomputesEveryPageLocally() async {
        let gallery = StubGalleryProvider(authored: authored, tagged: tagged)
        let (viewModel, snapshots) = makeViewModel(gallery: gallery)
        viewModel.viewDidLoad()
        await settle()

        viewModel.setGallerySource(.reposts)

        guard let snapshot = snapshots().last else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(snapshot.media == .content([
            tile("r-photo", kind: .photo, isRepost: true, publishedAtMS: 30),
            tile("r-video", kind: .video, isRepost: true, publishedAtMS: 20)
        ]))
        #expect(snapshot.short == .empty(message: "No short posts in reposts yet."))
        // No refetch: the source axis filters the cached datasets.
        #expect(await gallery.authoredCalls == 1)
        #expect(await gallery.taggedCalls == 1)
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
                reactionCount: .unavailable, viewCount: .unavailable
            )),
            gallery: StubGalleryProvider(authored: authored, tagged: tagged),
            galleryPreferences: preferences
        )
        first.setGalleryFormat(.media)
        first.setGallerySource(.reposts)

        // A NEW view model (a newly opened profile) lands on the stored pair.
        let second = ProfileViewModel(
            repository: StubProfileProvider(UserProfile(
                id: ProfileID("prof-2"), handle: "grace", displayName: "Grace", bio: "",
                avatarURL: nil, websiteURL: nil, isVerified: false,
                followerCount: .exact(0), followingCount: .exact(0),
                reactionCount: .unavailable, viewCount: .unavailable
            )),
            gallery: StubGalleryProvider(authored: authored, tagged: tagged),
            galleryPreferences: preferences
        )
        #expect(second.galleryFilter == GalleryFilter(format: .media, source: .reposts))
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
