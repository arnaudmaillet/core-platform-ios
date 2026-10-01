import CoreModels
import CoreNavigation
import Foundation
import MapsInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

/// **A pushed profile's first frame is its final one** (charter P12a).
///
/// Filmed on device, 1 October 2026: from a chat, the author's profile slid in
/// as its loading self — initials, bones, a BLUE "Follow" — and turned into the
/// real page ("Following", the face, the cards) as the slide ended. The data
/// was a few milliseconds away; it simply landed after the push had started.
///
/// The push is now held (`PresentationHold`) until the screen says it is
/// settled, and an unknown relationship no longer draws as "Follow" at all.
@MainActor
struct ProfilePushFirstFrameTests {
    // MARK: - Fixtures

    /// What these tests assert is WHY the hold let go, never how fast: the
    /// package's suites run in parallel on one main thread, and a full run
    /// was measured starving it for seven seconds. A ceiling the data can
    /// lose to under that load would make a timing bet of a behaviour test.
    private static let generousCeiling: TimeInterval = 60

    /// Real PNG bytes, so the pipeline decodes a picture rather than failing.
    private struct PictureFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data {
            await MainActor.run {
                UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData { context in
                    UIColor.systemTeal.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
                }
            }
        }
    }

    private struct EmptyGallery: ProfileGalleryProviding {
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    /// Answers the profile at once; the relationship either at once or never
    /// (a read stuck on the network), counting the reads it was asked for.
    private actor Profiles: ProfileProviding {
        let relationship: ProfileRelationship?
        private(set) var relationshipReads = 0
        init(relationship: ProfileRelationship?) { self.relationship = relationship }

        func currentUserProfile() async throws -> UserProfile { ProfilePushFirstFrameTests.kenji() }
        func profile(id: ProfileID) async throws -> UserProfile { ProfilePushFirstFrameTests.kenji() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
            relationshipReads += 1
            guard let relationship else {
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
            return relationship
        }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { ProfilePushFirstFrameTests.kenji() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { ProfilePushFirstFrameTests.kenji() }
    }

    nonisolated private static func kenji() -> UserProfile {
        UserProfile(
            id: ProfileID("prof-kenji"),
            handle: "kenji.dev",
            displayName: "Kenji Tanaka",
            bio: "Building small tools for small teams.",
            avatarURL: URL(string: "mock://avatar/kenji"),
            websiteURL: nil,
            isVerified: false,
            followerCount: .exact(4),
            followingCount: .exact(4),
            reactionCount: .exact(1_700)
        )
    }

    private func routedProfile(
        _ repository: Profiles, cache: ProfileCache? = nil, stub: ProfileIdentityStub? = nil
    ) -> ProfileViewController {
        ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository,
                gallery: EmptyGallery(),
                source: .profile(ProfileID("prof-kenji")),
                cache: cache
            ),
            imagePipeline: ImagePipeline(fetcher: PictureFetcher()),
            onLogout: nil,
            identityStub: stub
        )
    }

    /// Runs the hold the router runs, and reports why and when it let go.
    private func hold(
        _ screen: ProfileViewController, ceiling: TimeInterval
    ) async -> PresentationHold.Release {
        await withCheckedContinuation { continuation in
            PresentationHold.begin(screen, ceiling: ceiling) { release, _ in
                continuation.resume(returning: release)
            }
        }
    }

    // MARK: - The push waits for the settled page

    /// ⚠️ THE FILMED CASE: a followed author, data available within the
    /// budget. The push lets go because the screen is READY, not because the
    /// ceiling passed — and what it lets go of is the finished header.
    @Test func aProfileWhoseDataArrivesInTimeIsPushedAsItself() async {
        let screen = routedProfile(Profiles(relationship: .other(isFollowing: true, isBlocked: false)))

        let release = await hold(screen, ceiling: Self.generousCeiling)
        #expect(release == .ready, "the hold ran out instead of the page settling")
        #expect(!screen.debugIsHeaderRedacted, "pushed on the header's bones")
        #expect(screen.debugFollowTitle == "Following", "pushed wearing \(String(describing: screen.debugFollowTitle))")
        #expect(!screen.debugFollowIsProminent, "Following is a state, not the blue call to action")
        #expect(screen.debugHasAvatarPicture, "pushed on the initials instead of the face")
    }

    /// A stranger's profile settles on "Follow" — the prominent capsule is
    /// right when it is the ANSWER, not when it is a guess.
    @Test func aStrangersProfileSettlesOnFollow() async {
        let screen = routedProfile(Profiles(relationship: .other(isFollowing: false, isBlocked: false)))

        let release = await hold(screen, ceiling: Self.generousCeiling)

        #expect(release == .ready)
        #expect(screen.debugFollowTitle == "Follow")
        #expect(screen.debugFollowIsProminent)
    }

    /// The ceiling is what keeps the hold honest: a read that never answers
    /// costs the tap a bounded wait, and the screen goes on as it is.
    @Test func aRelationshipThatNeverAnswersReleasesAtTheCeiling() async {
        let screen = routedProfile(Profiles(relationship: nil))

        let release = await hold(screen, ceiling: 0.3)

        #expect(release == .ceiling)
    }

    // MARK: - An unknown relationship is never "Follow"

    /// ⚠️ THE BLUE BUTTON. Not knowing whether the viewer follows someone is
    /// not "they don't": the capsule holds a blank, inert placeholder — from
    /// the screen's first layout, and for as long as the read takes.
    @Test func anUnknownRelationshipNeverRendersAsFollow() async {
        let screen = routedProfile(Profiles(relationship: nil))

        screen.loadViewIfNeeded()
        #expect(screen.debugFollowTitle == nil, "the first frame claimed \(String(describing: screen.debugFollowTitle))")

        // The profile itself lands; the relationship does not.
        for _ in 0..<2000 where screen.debugIsHeaderRedacted {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!screen.debugIsHeaderRedacted, "the profile never loaded")
        #expect(screen.debugFollowTitle == nil, "an unread relationship drew as \(String(describing: screen.debugFollowTitle))")
        #expect(!screen.debugFollowIsProminent)
    }

    /// What the origin knew still counts: a stub that says "following" is an
    /// answer, and the capsule wears it from the first frame.
    @Test func anOriginsAnswerIsWornFromTheFirstFrame() {
        let screen = routedProfile(
            Profiles(relationship: nil),
            stub: ProfileIdentityStub(handle: "kenji.dev", displayName: "Kenji Tanaka", isFollowing: true)
        )
        screen.loadViewIfNeeded()
        #expect(screen.debugFollowTitle == "Following")
    }

    // MARK: - A revisit is ready at once

    /// ⚠️ A REVISIT'S HEADER DOES NOT WAIT. The profile AND the relationship
    /// come out of the cache in the same turn, so a screen with nothing else
    /// to fetch releases the hold before `begin` even returns — the push
    /// starts on the tap, already finished. (A gallery or a map star still
    /// costs its own read: measured ~90 ms on the simulator.)
    @Test func aRevisitsHeaderIsReadyBeforeAnyAwait() async {
        let cache = ProfileCache()
        let repository = Profiles(relationship: .other(isFollowing: true, isBlocked: false))
        // First visit: fills the cache (profile, relationship, picture).
        let pipeline = ImagePipeline(fetcher: PictureFetcher())
        let first = ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository, source: .profile(ProfileID("prof-kenji")), cache: cache
            ),
            imagePipeline: pipeline,
            onLogout: nil
        )
        _ = await hold(first, ceiling: Self.generousCeiling)
        #expect(cache.relationship(for: ProfileID("prof-kenji")) != nil, "the read was not remembered")

        let second = ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository, source: .profile(ProfileID("prof-kenji")), cache: cache
            ),
            imagePipeline: pipeline,
            onLogout: nil
        )
        var releasedSynchronously = false
        PresentationHold.begin(second, ceiling: 5) { release, _ in
            releasedSynchronously = release == .ready
        }
        #expect(releasedSynchronously, "a fully cached profile still waited for the network")
        #expect(second.debugFollowTitle == "Following")
    }

    /// A follow made elsewhere reaches the cached answer, so the next visit
    /// does not open on the old one and flip.
    @Test func aFollowMadeElsewhereUpdatesTheCachedAnswer() async {
        let cache = ProfileCache()
        let events = FollowGraphEvents()
        cache.observe(events)
        let id = ProfileID("prof-kenji")
        cache.store(.other(isFollowing: false, isBlocked: false), for: id)

        events.publish(FollowChange(profileID: id, isFollowing: true))
        for _ in 0..<2000 where cache.relationship(for: id) == .other(isFollowing: false, isBlocked: false) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(cache.relationship(for: id) == .other(isFollowing: true, isBlocked: false))
    }

    // MARK: - The map star is part of the settled tray

    /// Rails that answer only when told to.
    private actor GatedPinning: MapProfilePinning {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
        func categories(for id: ProfileID) async -> Set<MapFavoriteCategory> {
            if !isOpen { await withCheckedContinuation { waiters.append($0) } }
            return [.dock]
        }
        func setCategories(_ categories: Set<MapFavoriteCategory>, for id: ProfileID) async {}
    }

    /// ⚠️ FILMED: for someone followed, the star arrived mid-slide beside
    /// Message and squeezed both capsules to make room. Its rails are part of
    /// what the hold waits for.
    @Test func aFollowedProfileWaitsForItsMapStar() async {
        let pinning = GatedPinning()
        let viewModel = ProfileViewModel(
            repository: Profiles(relationship: .other(isFollowing: true, isBlocked: false)),
            mapPinning: pinning,
            source: .profile(ProfileID("prof-kenji"))
        )
        let screen = ProfileViewController(
            viewModel: viewModel,
            imagePipeline: ImagePipeline(fetcher: PictureFetcher()),
            onLogout: nil
        )
        var released = false
        PresentationHold.begin(screen, ceiling: Self.generousCeiling) { _, _ in released = true }
        for _ in 0..<2000 where !(viewModel.isRelationshipSettled && viewModel.profile != nil) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!released, "pushed before the star knew its rails")
        #expect(!viewModel.isMapPinSettled)

        await pinning.open()
        for _ in 0..<2000 where !released {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(released)
        #expect(viewModel.mapPinButton.isFavorited)
    }

    // MARK: - The two reads run side by side

    /// The relationship is asked for as the profile is, not after it: it needs
    /// only the id, and chained it was a second round trip in front of the
    /// one capsule a push would otherwise show as a placeholder.
    @Test func theRelationshipIsReadAlongsideTheProfile() async {
        let repository = Profiles(relationship: .other(isFollowing: true, isBlocked: false))
        let viewModel = ProfileViewModel(repository: repository, source: .profile(ProfileID("prof-kenji")))
        viewModel.viewDidLoad()
        for _ in 0..<2000 where !viewModel.isRelationshipSettled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(viewModel.isRelationshipSettled)
        // Settle the profile load too, then count: one read, not one per stage.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repository.relationshipReads == 1)
    }
}
