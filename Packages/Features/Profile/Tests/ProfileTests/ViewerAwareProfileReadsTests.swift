import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import PostGrid
import Testing
@testable import Profile

/// The profile screen reading the server's viewer-aware answers (#447,
/// backend #689/#691): a profile shown to no one but its owner reads as
/// unavailable, with nothing to retry and nothing cached standing in; a
/// private profile the viewer doesn't follow — what every guest is — shows
/// locked pages, not "No posts yet".
@MainActor
struct ViewerAwareProfileReadsTests {
    private actor Profiles: ProfileProviding {
        let shown: UserProfile
        private(set) var relation: ProfileRelationship
        private var isGone = false

        init(_ shown: UserProfile, relationship: ProfileRelationship) {
            self.shown = shown
            relation = relationship
        }

        func goAway() { isGone = true }
        func follow() { relation = .other(isFollowing: true, isBlocked: false) }

        func currentUserProfile() async throws -> UserProfile { shown }
        func profile(id: ProfileID) async throws -> UserProfile {
            if isGone { throw ProfileError.notFound }
            return shown
        }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { relation }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
            relation = .other(isFollowing: following, isBlocked: false)
        }
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile { shown }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { shown }
    }

    /// What the server sends: nothing for a private profile the viewer
    /// doesn't follow, one post otherwise.
    private actor Gallery: ProfileGalleryProviding {
        var posts: [GalleryPost]
        init(_ posts: [GalleryPost]) { self.posts = posts }
        func authoredPage(for profileID: ProfileID, after pageToken: String?) async throws -> GalleryPage {
            GalleryPage(posts: posts, nextPageToken: nil)
        }
        func taggedPage(for profileID: ProfileID, handle: String, after pageToken: String?) async throws -> GalleryPage {
            GalleryPage(posts: [], nextPageToken: nil)
        }
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { posts }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    private let id = ProfileID("prof-20")

    private func person(_ visibility: ProfileVisibility) -> UserProfile {
        UserProfile(
            id: id, handle: "nadia", displayName: "Nadia", bio: "", avatarURL: nil, websiteURL: nil,
            isVerified: false, visibility: visibility,
            followerCount: .exact(3), followingCount: .exact(3), reactionCount: .unavailable
        )
    }

    private let onePost = GalleryPost(
        id: PostID("p1"), kind: .photo, isRepost: false, thumbnailURL: nil, caption: "p1", publishedAtMS: 1
    )

    /// Waits for STATE, in looks (6,000 × 10 ms), never wall-clock time.
    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// What the screen was last told.
    @MainActor
    private final class Seen {
        var phase: ProfileViewModel.Phase?
        var gallery: ProfileViewModel.GallerySnapshot?
        var isContent: Bool { if case .content = phase { true } else { false } }
    }

    private func open(
        _ profiles: Profiles, gallery: Gallery? = nil, cache: ProfileCache? = nil
    ) -> (ProfileViewModel, Seen) {
        let viewModel = ProfileViewModel(repository: profiles, gallery: gallery, source: .profile(id), cache: cache)
        let seen = Seen()
        viewModel.onPhaseChange = { seen.phase = $0 }
        viewModel.onGalleryChange = { seen.gallery = $0 }
        viewModel.viewDidLoad()
        return (viewModel, seen)
    }

    // MARK: - Hidden, suspended, deleted

    @Test func aProfileShownToNoOneReadsUnavailableWithoutRetry() async throws {
        let profiles = Profiles(person(.public), relationship: .other(isFollowing: false, isBlocked: false))
        await profiles.goAway()
        let (viewModel, seen) = open(profiles)
        #expect(await settle { seen.phase == ProfileViewModel.unavailable })
        #expect(seen.phase == .notFound(message: "This account isn\u{2019}t available", detail: "It may have been removed or hidden."))
        withExtendedLifetime(viewModel) {}
    }

    /// Suspended while the viewer was away: the revisit replaces what it
    /// showed, and the cache forgets it.
    @Test func aProfileThatWentAwayReplacesWhatWasShownAndLeavesTheCache() async throws {
        let cache = ProfileCache()
        let profiles = Profiles(person(.public), relationship: .other(isFollowing: false, isBlocked: false))
        let (viewModel, seen) = open(profiles, cache: cache)
        try #require(await settle { seen.isContent && cache.profile(for: id) != nil })

        await profiles.goAway()
        viewModel.refresh()
        #expect(await settle { seen.phase == ProfileViewModel.unavailable })
        #expect(cache.profile(for: id) == nil)
    }

    @Test func theRepositoryReadsNotFoundAsAnAnswer() async throws {
        let backend = MockBackend()
        let client = backend.makeRPCClient()
        let repository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: MemberSession()
        )
        await #expect(throws: ProfileError.notFound) {
            _ = try await repository.profile(id: ProfileID("prof-no-one"))
        }
    }

    /// The mock's seeded hidden and suspended profiles (#447) — opened by
    /// id or by handle — read "This account isn't available".
    @Test(arguments: MockSocialServices.hiddenProfiles.map(\.id))
    func aSeededHiddenOrSuspendedProfileReadsUnavailable(id: String) async throws {
        let backend = MockBackend()
        let client = backend.makeRPCClient()
        let repository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: MemberSession()
        )
        let viewModel = ProfileViewModel(repository: repository, source: .profile(ProfileID(id)))
        var phase: ProfileViewModel.Phase?
        viewModel.onPhaseChange = { phase = $0 }
        viewModel.viewDidLoad()
        #expect(await settle { phase == ProfileViewModel.unavailable })
        withExtendedLifetime(viewModel) {}
    }

    // MARK: - Private profiles

    @Test func aPrivateProfileTheViewerDoesntFollowShowsLockedPages() async throws {
        let profiles = Profiles(person(.private), relationship: .other(isFollowing: false, isBlocked: false))
        let (viewModel, seen) = open(profiles, gallery: Gallery([]))
        #expect(await settle { seen.gallery?.activity == .restricted(title: ProfileViewModel.restrictedTitle, message: ProfileViewModel.restrictedMessage) })
        #expect(seen.gallery?.media == .restricted(title: ProfileViewModel.restrictedTitle, message: ProfileViewModel.restrictedMessage))
        #expect(viewModel.isPrivateToViewer)
    }

    /// A gallery that has not answered yet.
    private actor HangingGallery: ProfileGalleryProviding {
        func authoredPage(for profileID: ProfileID, after pageToken: String?) async throws -> GalleryPage {
            try await Task.sleep(for: .seconds(3600))
            return GalleryPage(posts: [], nextPageToken: nil)
        }
        func taggedPage(for profileID: ProfileID, handle: String, after pageToken: String?) async throws -> GalleryPage {
            try await Task.sleep(for: .seconds(3600))
            return GalleryPage(posts: [], nextPageToken: nil)
        }
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    /// #1900: known private and not followed, the pages the server withholds
    /// lock at once — before the gallery answers, with no bones in between.
    /// Tagged, which may hold other people's posts, keeps loading.
    @Test func aPrivateProfileLocksItsAuthoredPagesBeforeTheGalleryAnswers() async throws {
        let profiles = Profiles(person(.private), relationship: .other(isFollowing: false, isBlocked: false))
        let viewModel = ProfileViewModel(repository: profiles, gallery: HangingGallery(), source: .profile(id))
        let seen = Seen()
        viewModel.onGalleryChange = { seen.gallery = $0 }
        viewModel.viewDidLoad()
        let locked = ProfileViewModel.GalleryPageState.restricted(
            title: ProfileViewModel.restrictedTitle, message: ProfileViewModel.restrictedMessage
        )
        #expect(await settle { seen.gallery?.activity == locked }, "Posts waited on the gallery")
        #expect(seen.gallery?.media == locked)
        #expect(seen.gallery?.tagged == .loading, "Tagged no longer loads")
        #expect(viewModel.isGalleryLoading, "the premise: the gallery has not answered")
    }

    /// #1900: Try Again over pages that answered long ago republishes them —
    /// the page went back to loading on the tap and must hear back, even the
    /// same answer.
    @Test func tryAgainRepublishesTheSameAnswer() async throws {
        let profiles = Profiles(person(.private), relationship: .other(isFollowing: false, isBlocked: false))
        let viewModel = ProfileViewModel(repository: profiles, gallery: Gallery([]), source: .profile(id))
        var publications = 0
        viewModel.onGalleryChange = { _ in publications += 1 }
        viewModel.viewDidLoad()
        try #require(await settle { !viewModel.isGalleryLoading && publications > 0 })
        let before = publications
        let shown = viewModel.publishedGallery
        viewModel.retryGallery()
        #expect(publications > before, "Try Again published nothing")
        #expect(viewModel.publishedGallery == shown)
    }

    /// Every guest: the relationship a guest reads is "not following"
    /// (`ProfileRepositoryTests.aGuestFollowsNoOne`), so the same locked pages.
    @Test func aGuestSeesAPrivateProfileLocked() async throws {
        let backend = MockBackend()
        let client = backend.makeRPCClient()
        let repository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: GuestSession()
        )
        let relation = try await repository.relationship(for: ProfileID("prof-1"))
        let profiles = Profiles(person(.private), relationship: relation)
        let (viewModel, seen) = open(profiles, gallery: Gallery([]))
        #expect(await settle { if case .restricted = seen.gallery?.activity { true } else { false } })
        withExtendedLifetime(viewModel) {}
    }

    @Test func aFollowedPrivateProfileShowsItsPostsAndAPublicOneItsEmptiness() async throws {
        let followed = Profiles(person(.private), relationship: .other(isFollowing: true, isBlocked: false))
        let (followedModel, followedSeen) = open(followed, gallery: Gallery([onePost]))
        #expect(await settle { followedSeen.gallery?.activity == .content([onePost]) })
        withExtendedLifetime(followedModel) {}

        let bare = Profiles(person(.public), relationship: .other(isFollowing: false, isBlocked: false))
        let (viewModel, bareSeen) = open(bare, gallery: Gallery([]))
        #expect(await settle { if case .empty = bareSeen.gallery?.activity { true } else { false } })
        #expect(!viewModel.isPrivateToViewer)
    }

    /// Following from the header unlocks the pages at once.
    @Test func followingUnlocksThePages() async throws {
        let profiles = Profiles(person(.private), relationship: .other(isFollowing: false, isBlocked: false))
        let (viewModel, seen) = open(profiles, gallery: Gallery([]))
        try #require(await settle { if case .restricted = seen.gallery?.activity { true } else { false } })
        try #require(await settle { viewModel.isRelationshipSettled })
        viewModel.toggleFollow()
        #expect(await settle { !viewModel.isPrivateToViewer })
        #expect(await settle { if case .restricted = seen.gallery?.activity { false } else { seen.gallery != nil } })
    }

    /// A follow toggle redraws the header from the same profile: its banner
    /// (#944) and its avatar frame (#943) stay — the banner used to fall back
    /// to the avatar.
    @Test func aFollowToggleKeepsTheBannerAndTheFrame() async throws {
        let dressed = UserProfile(
            id: id, handle: "nadia", displayName: "Nadia", bio: "",
            avatarURL: URL(string: "https://cdn.example/face.jpg"),
            bannerURL: URL(string: "https://cdn.example/banner.jpg"),
            bannerVideoURL: URL(string: "https://cdn.example/banner.m3u8"), websiteURL: nil,
            isVerified: false, visibility: .public,
            followerCount: .exact(3), followingCount: .exact(3), reactionCount: .unavailable,
            avatarFrameID: "frame.gold"
        )
        let profiles = Profiles(dressed, relationship: .other(isFollowing: false, isBlocked: false))
        let (viewModel, seen) = open(profiles, gallery: Gallery([]))
        try #require(await settle { seen.isContent && viewModel.isRelationshipSettled })
        viewModel.toggleFollow()
        guard case .content(let model) = seen.phase else {
            Issue.record("no content after the toggle")
            return
        }
        #expect(model.followerText == "4")
        #expect(model.bannerImageURL == dressed.bannerURL)
        #expect(model.bannerVideoURL == dressed.bannerVideoURL)
        #expect(model.avatarFrameID == "frame.gold")
    }
}

private struct MemberSession: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
    func logout() async {}
}

private struct GuestSession: AuthSessionProviding {
    func currentState() async -> AuthState { .unauthenticated }
    func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
    func logout() async {}
}
