import CoreModels
import CoreNavigation
import Foundation
import Testing
@testable import Profile

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private actor StubProfileProvider: ProfileProviding {
    enum Outcome {
        case success(UserProfile)
        case failure(Error)
    }

    private let outcome: Outcome
    private let stubRelationship: ProfileRelationship
    private var setFollowingError: Error?

    private(set) var callCount = 0
    private(set) var lastRequestedID: ProfileID?
    private(set) var followCalls: [(following: Bool, id: ProfileID)] = []

    init(_ outcome: Outcome, relationship: ProfileRelationship = .other(isFollowing: false), setFollowingError: Error? = nil) {
        self.outcome = outcome
        self.stubRelationship = relationship
        self.setFollowingError = setFollowingError
    }

    func currentUserProfile() async throws -> UserProfile {
        try await resolve()
    }

    func profile(id: ProfileID) async throws -> UserProfile {
        lastRequestedID = id
        return try await resolve()
    }

    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
        stubRelationship
    }

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        followCalls.append((following, profileID))
        if let setFollowingError { throw setFollowingError }
    }

    func updateCurrentUserProfile(displayName: String, bio: String, website: String) async throws -> UserProfile {
        try await resolve()
    }

    private func resolve() async throws -> UserProfile {
        callCount += 1
        switch outcome {
        case .success(let profile): return profile
        case .failure(let error): throw error
        }
    }
}

private struct SampleError: Error {}

private func sampleProfile(followers: CountEstimate = .exact(1_234)) -> UserProfile {
    UserProfile(
        id: ProfileID("prof-1"),
        handle: "ada",
        displayName: "Ada Lovelace",
        bio: "Countess of computing",
        avatarURL: nil,
        websiteURL: nil,
        isVerified: true,
        followerCount: followers,
        followingCount: .exact(56),
        reactionCount: .exact(9_800),
        viewCount: .atLeast(120_000)
    )
}

@MainActor
struct ProfileViewModelTests {
    private func phaseRecorder(_ viewModel: ProfileViewModel) -> () -> [ProfileViewModel.Phase] {
        let box = Box<ProfileViewModel.Phase>()
        viewModel.onPhaseChange = { box.append($0) }
        return { box.items }
    }

    private func followRecorder(_ viewModel: ProfileViewModel) -> () -> [ProfileViewModel.FollowButton] {
        let box = Box<ProfileViewModel.FollowButton>()
        viewModel.onFollowButtonChange = { box.append($0) }
        return { box.items }
    }

    /// Drives viewDidLoad and lets the load + relationship tasks settle.
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func lastFollowerText(_ phases: () -> [ProfileViewModel.Phase]) -> String? {
        for phase in phases().reversed() {
            if case .content(let model) = phase { return model.followerText }
        }
        return nil
    }

    @Test func loadsProfileIntoContentPhase() async {
        let viewModel = ProfileViewModel(repository: StubProfileProvider(.success(sampleProfile())))
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle()

        let last = phases().last
        guard case .content(let model) = last else {
            Issue.record("expected content phase, got \(String(describing: last))")
            return
        }
        #expect(model.handle == "@ada")
        #expect(model.followerText == "1.2K")
        #expect(model.isVerified)
    }

    @Test func routedSourceLoadsThatProfileByID() async {
        let provider = StubProfileProvider(.success(sampleProfile()))
        let viewModel = ProfileViewModel(repository: provider, source: .profile(ProfileID("prof-42")))
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle()

        #expect(await provider.lastRequestedID == ProfileID("prof-42"))
        guard case .content = phases().last else {
            Issue.record("expected content phase")
            return
        }
    }

    @Test func surfacesFailureWhenNothingLoaded() async {
        let viewModel = ProfileViewModel(repository: StubProfileProvider(.failure(SampleError())))
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle()

        guard case .failed = phases().last else {
            Issue.record("expected failed phase, got \(String(describing: phases().last))")
            return
        }
    }

    // MARK: - Follow button

    @Test func ownProfileShowsEditButton() async {
        let viewModel = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile()), relationship: .me)
        )
        let follow = followRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle()

        #expect(follow().last == .edit)
    }

    @Test func otherProfileShowsFollowOrFollowing() async {
        let notFollowing = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile()), relationship: .other(isFollowing: false)),
            source: .profile(ProfileID("prof-1"))
        )
        let notFollowingStates = followRecorder(notFollowing)
        notFollowing.viewDidLoad()
        await settle()
        #expect(notFollowingStates().last == .follow)

        let following = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile()), relationship: .other(isFollowing: true)),
            source: .profile(ProfileID("prof-1"))
        )
        let followingStates = followRecorder(following)
        following.viewDidLoad()
        await settle()
        #expect(followingStates().last == .following)
    }

    @Test func tappingFollowOptimisticallyUpdatesButtonAndCount() async {
        let provider = StubProfileProvider(
            .success(sampleProfile(followers: .exact(10))),
            relationship: .other(isFollowing: false)
        )
        let viewModel = ProfileViewModel(repository: provider, source: .profile(ProfileID("prof-1")))
        let follow = followRecorder(viewModel)
        let phases = phaseRecorder(viewModel)
        viewModel.viewDidLoad()
        await settle()

        viewModel.toggleFollow()
        // Optimistic: button + count flip before the network settles.
        #expect(follow().last == .following)
        #expect(lastFollowerText(phases) == "11")

        await settle()
        let calls = await provider.followCalls
        #expect(calls.count == 1)
        #expect(calls.first?.following == true)
        #expect(calls.first?.id == ProfileID("prof-1"))
    }

    @Test func failedFollowRollsBackButtonAndCount() async {
        let provider = StubProfileProvider(
            .success(sampleProfile(followers: .exact(10))),
            relationship: .other(isFollowing: false),
            setFollowingError: SampleError()
        )
        let viewModel = ProfileViewModel(repository: provider, source: .profile(ProfileID("prof-1")))
        let follow = followRecorder(viewModel)
        let phases = phaseRecorder(viewModel)
        viewModel.viewDidLoad()
        await settle()

        viewModel.toggleFollow()
        await settle()

        // Rolled back to the pre-tap state.
        #expect(follow().last == .follow)
        #expect(lastFollowerText(phases) == "10")
    }

    @Test func messageTappedRoutesToDirectMessageForOthers() async {
        let router = SpyRouter()
        let viewModel = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile()), relationship: .other(isFollowing: false)),
            source: .profile(ProfileID("prof-1")),
            router: router
        )
        viewModel.viewDidLoad()
        await settle()

        viewModel.messageTapped()
        #expect(router.routes == [.messageUser(ProfileID("prof-1"))])
    }

    @Test func messageTappedIsANoOpOnOwnProfile() async {
        let router = SpyRouter()
        let viewModel = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile()), relationship: .me),
            router: router
        )
        viewModel.viewDidLoad()
        await settle()

        viewModel.messageTapped()
        #expect(router.routes.isEmpty)
    }

    @Test func editButtonTapIsANoOp() async {
        let provider = StubProfileProvider(.success(sampleProfile()), relationship: .me)
        let viewModel = ProfileViewModel(repository: provider)
        viewModel.viewDidLoad()
        await settle()

        viewModel.toggleFollow()
        await settle()

        #expect(await provider.followCalls.isEmpty)
    }
}

/// Main-actor-isolated collector for values emitted on the main actor.
@MainActor
private final class Box<T> {
    private(set) var items: [T] = []
    func append(_ item: T) { items.append(item) }
}
