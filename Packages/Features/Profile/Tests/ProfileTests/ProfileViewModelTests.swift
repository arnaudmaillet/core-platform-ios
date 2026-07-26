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
    private var setBlockedError: Error?

    private(set) var callCount = 0
    private(set) var lastRequestedID: ProfileID?
    private(set) var followCalls: [(following: Bool, id: ProfileID)] = []
    private(set) var blockCalls: [(blocked: Bool, id: ProfileID)] = []
    private(set) var accountBlockCalls: [ProfileID] = []
    /// What an account-wide block resolves to — the aliases the fleet let us
    /// see, which is the whole point of reporting a count back.
    private var accountBlockResult: [ProfileID] = []

    init(
        _ outcome: Outcome,
        relationship: ProfileRelationship = .other(isFollowing: false, isBlocked: false),
        setFollowingError: Error? = nil,
        setBlockedError: Error? = nil,
        accountBlockResult: [ProfileID] = []
    ) {
        self.outcome = outcome
        self.stubRelationship = relationship
        self.setFollowingError = setFollowingError
        self.setBlockedError = setBlockedError
        self.accountBlockResult = accountBlockResult
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

    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {
        blockCalls.append((blocked, profileID))
        if let setBlockedError { throw setBlockedError }
    }

    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] {
        accountBlockCalls.append(profileID)
        if let setBlockedError { throw setBlockedError }
        return accountBlockResult.isEmpty ? [profileID] : accountBlockResult
    }

    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile {
        try await resolve()
    }
    func changeHandle(_ newHandle: String) async throws -> UserProfile {
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

    private func actionRecorder(_ viewModel: ProfileViewModel) -> () -> [ProfileViewModel.ActionResult] {
        let box = Box<ProfileViewModel.ActionResult>()
        viewModel.onActionResult = { box.append($0) }
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
            repository: StubProfileProvider(.success(sampleProfile()), relationship: .other(isFollowing: false, isBlocked: false)),
            source: .profile(ProfileID("prof-1"))
        )
        let notFollowingStates = followRecorder(notFollowing)
        notFollowing.viewDidLoad()
        await settle()
        #expect(notFollowingStates().last == .follow)

        let following = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile()), relationship: .other(isFollowing: true, isBlocked: false)),
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
            relationship: .other(isFollowing: false, isBlocked: false)
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
            relationship: .other(isFollowing: false, isBlocked: false),
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
            repository: StubProfileProvider(.success(sampleProfile()), relationship: .other(isFollowing: false, isBlocked: false)),
            source: .profile(ProfileID("prof-1")),
            router: router
        )
        viewModel.viewDidLoad()
        await settle()

        viewModel.messageTapped()
        // The profile's identity rides the route: the thread opens before its
        // conversation is known to exist, so this is what titles its header.
        #expect(router.routes == [.messageUser(
            ProfileID("prof-1"),
            stub: ProfileIdentityStub(handle: "ada", displayName: "Ada Lovelace")
        )])
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

    // MARK: - Overflow menu

    @Test func shareLinkIsBuiltFromTheHandleOnceLoaded() async {
        let viewModel = ProfileViewModel(repository: StubProfileProvider(.success(sampleProfile())))
        // Nothing to share before the profile resolves — the menu omits the
        // sharing group rather than offering a dead action.
        #expect(viewModel.shareLink == nil)

        viewModel.viewDidLoad()
        await settle()

        #expect(viewModel.shareLink?.absoluteString == "https://wynn.cn/@ada")
        #expect(viewModel.handle == "@ada")
    }

    @Test func blockingReportsAndAsksTheScreenToLeave() async {
        let provider = StubProfileProvider(.success(sampleProfile()))
        let viewModel = ProfileViewModel(repository: provider)
        let results = actionRecorder(viewModel)
        let dismissals = Box<Void>()
        viewModel.onDismissRequested = { dismissals.append(()) }

        viewModel.viewDidLoad()
        await settle()
        viewModel.block(.profile)
        await settle()

        #expect(await provider.blockCalls.map(\.blocked) == [true])
        // Profile scope must never touch the account fan-out.
        #expect(await provider.accountBlockCalls.isEmpty)
        #expect(results() == [.blocked(handle: "@ada", profileCount: 1)])
        #expect(dismissals.items.count == 1)
        #expect(viewModel.isBlocked)
    }

    /// Account scope reports how many profiles were ACTUALLY blocked, so the
    /// confirmation can't claim aliases the fleet never surfaced.
    @Test func accountBlockReportsTheProfilesItActuallyCovered() async {
        let provider = StubProfileProvider(
            .success(sampleProfile()),
            accountBlockResult: [ProfileID("prof-1"), ProfileID("prof-9"), ProfileID("prof-12")]
        )
        let viewModel = ProfileViewModel(repository: provider)
        let results = actionRecorder(viewModel)
        let dismissals = Box<Void>()
        viewModel.onDismissRequested = { dismissals.append(()) }

        viewModel.viewDidLoad()
        await settle()
        viewModel.block(.account)
        await settle()

        #expect(await provider.accountBlockCalls == [ProfileID("prof-1")])
        // The single-profile command is NOT also sent — the fan-out owns it.
        #expect(await provider.blockCalls.isEmpty)
        #expect(results() == [.blocked(handle: "@ada", profileCount: 3)])
        #expect(dismissals.items.count == 1)
        #expect(viewModel.isBlocked)
    }

    /// An account block that only reached the one profile reports 1, not 3 —
    /// the degraded case the fleet will hit until it exposes account aliases.
    @Test func accountBlockThatReachedOnlyOneProfileSaysSo() async {
        let viewModel = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile()), accountBlockResult: [ProfileID("prof-1")])
        )
        let results = actionRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle()
        viewModel.block(.account)
        await settle()

        #expect(results() == [.blocked(handle: "@ada", profileCount: 1)])
    }

    /// Block is NOT optimistic: a rejected block must leave the screen's state
    /// untouched and must not navigate away, or the user believes a block
    /// happened that didn't.
    @Test func failedBlockKeepsStateAndDoesNotLeave() async {
        let viewModel = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile()), setBlockedError: SampleError())
        )
        let results = actionRecorder(viewModel)
        let dismissals = Box<Void>()
        viewModel.onDismissRequested = { dismissals.append(()) }

        viewModel.viewDidLoad()
        await settle()
        viewModel.block(.profile)
        await settle()

        #expect(!viewModel.isBlocked)
        #expect(dismissals.items.isEmpty)
        #expect(results() == [.failed(message: "Couldn't block this profile.")])
    }

    @Test func unblockingReportsWithoutLeaving() async {
        let provider = StubProfileProvider(
            .success(sampleProfile()),
            relationship: .other(isFollowing: false, isBlocked: true)
        )
        let viewModel = ProfileViewModel(repository: provider)
        let results = actionRecorder(viewModel)
        let dismissals = Box<Void>()
        viewModel.onDismissRequested = { dismissals.append(()) }

        viewModel.viewDidLoad()
        await settle()
        #expect(viewModel.isBlocked)

        viewModel.unblock()
        await settle()

        #expect(await provider.blockCalls.map(\.blocked) == [false])
        #expect(results() == [.unblocked(handle: "@ada")])
        #expect(dismissals.items.isEmpty)
        #expect(!viewModel.isBlocked)
    }

    @Test func ownProfileCannotBeBlockedOrReported() async {
        let provider = StubProfileProvider(.success(sampleProfile()), relationship: .me)
        let reporter = StubReporter()
        let viewModel = ProfileViewModel(repository: provider, reporting: reporter)
        viewModel.viewDidLoad()
        await settle()

        #expect(!viewModel.canModerate)
        viewModel.block(.profile)
        viewModel.block(.account)
        viewModel.report(.spam)
        await settle()

        #expect(await provider.blockCalls.isEmpty)
        #expect(await provider.accountBlockCalls.isEmpty)
        #expect(await reporter.reports.isEmpty)
    }

    @Test func reportForwardsTheChosenReason() async {
        let reporter = StubReporter()
        let viewModel = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile())), reporting: reporter
        )
        let results = actionRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle()
        viewModel.report(.harassment)
        await settle()

        let filed = await reporter.reports
        #expect(filed.count == 1)
        #expect(filed.first?.id == ProfileID("prof-1"))
        #expect(filed.first?.reason == .harassment)
        #expect(results() == [.reported])
    }

    /// A report that didn't land must say so — a user who believes they
    /// reported someone and didn't is the worst outcome for this flow.
    @Test func failedReportIsSurfaced() async {
        let viewModel = ProfileViewModel(
            repository: StubProfileProvider(.success(sampleProfile())),
            reporting: StubReporter(error: SampleError())
        )
        let results = actionRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle()
        viewModel.report(.spam)
        await settle()

        #expect(results() == [.failed(message: "Couldn't send this report. Try again.")])
    }

    @Test func reportWithoutABackendSaysSoRatherThanSucceedingSilently() async {
        let viewModel = ProfileViewModel(repository: StubProfileProvider(.success(sampleProfile())))
        let results = actionRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle()
        viewModel.report(.spam)
        await settle()

        #expect(results() == [.failed(message: "Reporting isn't available right now.")])
    }
}

private actor StubReporter: ProfileReporting {
    private let error: Error?
    private(set) var reports: [(id: ProfileID, reason: ProfileReportReason)] = []

    init(error: Error? = nil) { self.error = error }

    func reportProfile(_ profileID: ProfileID, reason: ProfileReportReason) async throws {
        reports.append((profileID, reason))
        if let error { throw error }
    }
}

/// Main-actor-isolated collector for values emitted on the main actor.
@MainActor
private final class Box<T> {
    private(set) var items: [T] = []
    func append(_ item: T) { items.append(item) }
}
