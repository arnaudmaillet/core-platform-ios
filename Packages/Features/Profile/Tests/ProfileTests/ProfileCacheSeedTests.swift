import CoreModels
import Foundation
import Testing
@testable import Profile

private actor SeedStubProvider: ProfileProviding {
    let profile: UserProfile
    private(set) var reads = 0
    init(profile: UserProfile) { self.profile = profile }

    func currentUserProfile() async throws -> UserProfile { profile }
    func profile(id: ProfileID) async throws -> UserProfile {
        reads += 1
        return profile
    }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile { profile }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { profile }
}

private func someone() -> UserProfile {
    UserProfile(
        id: ProfileID("prof-7"),
        handle: "grace",
        displayName: "Grace Hopper",
        bio: "Nanoseconds",
        avatarURL: nil,
        websiteURL: nil,
        customLinks: [],
        isVerified: true,
        followerCount: .exact(1),
        followingCount: .exact(2),
        reactionCount: .unavailable,
        viewCount: .unavailable
    )
}

/// Charter P7: a profile the cache holds renders at frame 0 on a revisit,
/// and the fetch that follows confirms it without re-rendering.
@MainActor
struct ProfileCacheSeedTests {
    @Test func aRevisitRendersTheCachedProfileBeforeAnyAwait() async {
        let cache = ProfileCache()
        cache.store(someone())
        let provider = SeedStubProvider(profile: someone())
        let viewModel = ProfileViewModel(repository: provider, source: .profile(ProfileID("prof-7")), cache: cache)
        var phases: [ProfileViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }

        viewModel.viewDidLoad()
        guard case .content(let model)? = phases.first else {
            Issue.record("expected content before any await, got \(String(describing: phases.first))")
            return
        }
        #expect(model.displayName == "Grace Hopper")

        for _ in 0..<60 where await provider.reads == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await provider.reads == 1, "the fetch still runs, to confirm the cache")
        #expect(phases.count == 1, "an unchanged profile is not re-rendered")
    }

    @Test func aFirstVisitStillOpensOnTheSkeleton() async {
        let viewModel = ProfileViewModel(
            repository: SeedStubProvider(profile: someone()),
            source: .profile(ProfileID("prof-7")), cache: ProfileCache()
        )
        var phases: [ProfileViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.viewDidLoad()
        #expect(phases.isEmpty, "nothing to seed, so the phase stays .loading until the fetch")
    }
}
