import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Mute (#403, backend #722), end to end over the mock BFF: the profile
/// menu's per-scope toggles and Settings → Safety → Muted Accounts.
@MainActor
struct MuteTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func makeRepository() -> ProfileRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(dataset: dataset, isPrivate: { social.isPrivate($0) }).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )
    }

    /// Waits on STATE, not time: polls until `condition` holds, for up to
    /// 10 s, and returns at once when it does. The bound is generous because
    /// a starved CI runner took over two minutes on this suite; a short
    /// budget that gave up silently made the next step a no-op (#521).
    @discardableResult
    private func settle(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Muting stores the scopes, re-muting replaces them, the relation reads
    /// them back, and none unmutes. Follows are untouched.
    @Test func scopesRoundTripAndNoneUnmutes() async throws {
        let repository = makeRepository()
        let target = ProfileID("prof-3")
        let relationBefore = try await repository.followRelation(to: target)
        #expect(try await repository.muteScopes(for: target) == .none)

        try await repository.setMuteScopes(MuteScopes(posts: true, messages: true), for: target)
        #expect(try await repository.muteScopes(for: target) == MuteScopes(posts: true, messages: true))
        try await repository.setMuteScopes(MuteScopes(stories: true), for: target)
        #expect(try await repository.muteScopes(for: target) == MuteScopes(stories: true))
        #expect(try await repository.followRelation(to: target) == relationBefore, "a mute isn't a block")

        try await repository.setMuteScopes(.none, for: target)
        #expect(try await repository.muteScopes(for: target) == .none)
    }

    /// The muted list is hydrated, newest first, and Unmute drops the row.
    @Test func theMutedListUnmutes() async throws {
        let repository = makeRepository()
        try await repository.setMuteScopes(MuteScopes(posts: true), for: ProfileID("prof-7"))
        try await Task.sleep(for: .milliseconds(20))
        try await repository.setMuteScopes(MuteScopes(messages: true), for: ProfileID("prof-3"))

        let viewModel = MutedAccountsViewModel(muting: repository)
        await viewModel.load()
        guard case .loaded(let muted) = viewModel.phase else {
            Issue.record("the list didn't load")
            return
        }
        #expect(muted.map(\.id.rawValue) == ["prof-3", "prof-7"])
        #expect(muted.allSatisfy { $0.handle != $0.id.rawValue })
        #expect(MutedAccountsViewModel.detail(for: muted[0]) == "@\(muted[0].handle) · Messages")

        try await viewModel.unmute(muted[0])
        guard case .loaded(let left) = viewModel.phase else { return }
        #expect(left.map(\.id.rawValue) == ["prof-7"])
        #expect(try await repository.muteScopes(for: ProfileID("prof-3")) == .none)
    }

    /// The profile's toggle flips one scope at once and says so.
    @Test func theProfileMenuTogglesOneScope() async throws {
        let repository = makeRepository()
        let target = ProfileID("prof-3")
        let viewModel = ProfileViewModel(repository: repository, source: .profile(target))
        var results: [ProfileViewModel.ActionResult] = []
        viewModel.onActionResult = { results.append($0) }
        viewModel.viewDidLoad()
        // Both reads: the relationship can answer before the profile, and the
        // menu acts on a loaded profile only.
        try #require(await settle { viewModel.canModerate && viewModel.profile != nil }, "the profile never loaded")
        #expect(viewModel.canMute)

        viewModel.toggleMute(.posts)
        #expect(viewModel.muteScopes == MuteScopes(posts: true), "optimistic")
        await settle { !results.isEmpty }
        guard case .muteChanged(_, let scopes) = results.last else {
            Issue.record("no confirmation: \(results)")
            return
        }
        #expect(scopes == MuteScopes(posts: true))
        #expect(try await repository.muteScopes(for: target) == MuteScopes(posts: true))
    }

    @Test func theToastSaysWhatIsMuted() {
        #expect(ProfileViewModel.muteMessage(handle: "@ada", scopes: .none) == "Unmuted @ada")
        #expect(ProfileViewModel.muteMessage(handle: "@ada", scopes: MuteScopes(posts: true)) == "Muted @ada's posts")
        #expect(ProfileViewModel.muteMessage(handle: "@ada", scopes: MuteScopes(posts: true, messages: true)) == "Muted @ada's posts and messages")
        #expect(ProfileViewModel.muteMessage(handle: "@ada", scopes: MuteScopes(posts: true, stories: true, messages: true)) == "Muted @ada's posts, stories and messages")
        #expect(MutedAccountsViewController.footer.contains("aren't told"))
    }
}
