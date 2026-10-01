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
///
/// ⚠️ NO TEST HERE RACES A CLOCK. Every hold runs with a `.manual` ceiling:
/// a test that asserts `.ready` has no timer to lose to, and the one that
/// asserts `.ceiling` fires it itself. Waits poll the actual signal, with no
/// bound but the suite's time limit. CI's first run of this suite took ~105 s
/// per test — the whole package was starved — and every wall-clock ceiling,
/// even a "generous" 60 s, fired before the page it bounded had settled.
@MainActor
@Suite(.timeLimit(.minutes(10)))
struct ProfilePushFirstFrameTests {
    // MARK: - Fixtures

    /// A 4×6 PNG, as bytes. Not drawn per fetch: rendering one needs the
    /// main actor, and a starved main actor is exactly what this suite must
    /// not depend on.
    nonisolated private static let picture = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAGCAYAAADkOT91AAAAEklEQVR4nGPQWLDqPzJmoIUAAI6fOpk1HP8vAAAAAElFTkSuQmCC"
    )!

    /// Real PNG bytes, so the pipeline decodes a picture rather than failing.
    private struct PictureFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { ProfilePushFirstFrameTests.picture }
    }

    /// Returns once `condition` holds — polled, never timed. A cancelled test
    /// (the suite's time limit) stops polling.
    private func settle(until condition: () -> Bool) async {
        while !condition(), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
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
                // Never answers: suspended until the test is torn down.
                try await Task.sleep(for: .seconds(3600))
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

    /// Runs the hold the router runs — with no ceiling: the only way out is
    /// the screen saying it is ready.
    private func holdUntilReady(_ screen: ProfileViewController) async -> PresentationHold.Release {
        await withCheckedContinuation { continuation in
            PresentationHold.begin(screen, ceiling: .manual) { release, _ in
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

        let release = await holdUntilReady(screen)
        #expect(release == .ready)
        #expect(!screen.debugIsHeaderRedacted, "pushed on the header's bones")
        #expect(screen.debugFollowTitle == "Following", "pushed wearing \(String(describing: screen.debugFollowTitle))")
        #expect(!screen.debugFollowIsProminent, "Following is a state, not the blue call to action")
        #expect(screen.debugHasAvatarPicture, "pushed on the initials instead of the face")
    }

    /// A stranger's profile settles on "Follow" — the prominent capsule is
    /// right when it is the ANSWER, not when it is a guess.
    @Test func aStrangersProfileSettlesOnFollow() async {
        let screen = routedProfile(Profiles(relationship: .other(isFollowing: false, isBlocked: false)))

        let release = await holdUntilReady(screen)

        #expect(release == .ready)
        #expect(screen.debugFollowTitle == "Follow")
        #expect(screen.debugFollowIsProminent)
    }

    /// The ceiling is what keeps the hold honest: a read that never answers
    /// is never waited out — the push goes ahead on what the page has, and
    /// what it has is a placeholder, not a guess.
    @Test func aRelationshipThatNeverAnswersIsPushedOnItsPlaceholder() async {
        let screen = routedProfile(Profiles(relationship: nil))
        var releases: [PresentationHold.Release] = []
        let hold = PresentationHold.begin(screen, ceiling: .manual) { release, _ in releases.append(release) }

        // The profile lands; the relationship never does, so nothing releases.
        await settle(until: { !screen.debugIsHeaderRedacted })
        #expect(releases.isEmpty, "released without a relationship")

        hold.releaseAtCeiling()

        #expect(releases == [.ceiling])
        #expect(screen.debugFollowTitle == nil, "pushed wearing \(String(describing: screen.debugFollowTitle))")
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
        await settle(until: { !screen.debugIsHeaderRedacted })
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
    ///
    /// Everything it reads is its own — a fresh cache and a fresh pipeline —
    /// so no other suite can warm or cool it. Its CI failure was the first
    /// visit's hold running out on a starved runner before the picture was
    /// decoded: the second visit then really did have to wait for it. The
    /// first visit now ends on READY, and the test says so before relying on it.
    @Test func aRevisitsHeaderIsReadyBeforeAnyAwait() async throws {
        let id = ProfileID("prof-kenji")
        let cache = ProfileCache()
        let repository = Profiles(relationship: .other(isFollowing: true, isBlocked: false))
        // First visit: fills the cache (profile, relationship, picture).
        let pipeline = ImagePipeline(fetcher: PictureFetcher())
        let first = ProfileViewController(
            viewModel: ProfileViewModel(repository: repository, source: .profile(id), cache: cache),
            imagePipeline: pipeline,
            onLogout: nil
        )
        #expect(await holdUntilReady(first) == .ready)
        try #require(cache.profile(for: id) != nil, "the first visit's profile was not cached")
        try #require(cache.relationship(for: id) != nil, "the first visit's relationship was not cached")
        let avatar = try #require(ProfilePushFirstFrameTests.kenji().avatarURL)
        try #require(pipeline.cachedImage(for: avatar) != nil, "the first visit's picture was not cached")

        let second = ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository, source: .profile(ProfileID("prof-kenji")), cache: cache
            ),
            imagePipeline: pipeline,
            onLogout: nil
        )
        var releasedSynchronously = false
        PresentationHold.begin(second, ceiling: .manual) { release, _ in
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
        await settle(until: { cache.relationship(for: id) != .other(isFollowing: false, isBlocked: false) })

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
        var releases: [PresentationHold.Release] = []
        let hold = PresentationHold.begin(screen, ceiling: .manual) { release, _ in releases.append(release) }
        // Everything but the star lands; the rails are gated shut.
        await settle(until: {
            viewModel.isRelationshipSettled && !screen.debugIsHeaderRedacted && screen.debugHasAvatarPicture
        })
        #expect(releases.isEmpty, "pushed before the star knew its rails")
        #expect(!viewModel.isMapPinSettled)

        await pinning.open()
        await settle(until: { !releases.isEmpty })

        #expect(releases == [.ready])
        #expect(viewModel.mapPinButton.isFavorited)
        withExtendedLifetime(hold) {}
    }

    // MARK: - The two reads run side by side

    /// The relationship is asked for as the profile is, not after it: it needs
    /// only the id, and chained it was a second round trip in front of the
    /// one capsule a push would otherwise show as a placeholder.
    @Test func theRelationshipIsReadAlongsideTheProfile() async {
        let repository = Profiles(relationship: .other(isFollowing: true, isBlocked: false))
        let viewModel = ProfileViewModel(repository: repository, source: .profile(ProfileID("prof-kenji")))
        var settled = false
        viewModel.onLoadSettled = { settled = true }
        viewModel.viewDidLoad()
        // Both reads have landed: the profile load says so itself, and the
        // relationship flag is the read's own answer.
        await settle(until: { settled && viewModel.isRelationshipSettled })

        #expect(await repository.relationshipReads == 1, "one read, not one per stage")
    }
}
