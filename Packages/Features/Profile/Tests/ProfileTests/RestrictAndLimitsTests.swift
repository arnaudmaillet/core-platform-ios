import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile
@testable import ProfileData

/// Restrict from the profile's menu (#416; backend #724), end to end over the
/// mock BFF. The settings side is `RestrictAndLimitsSettingsTests`.
@MainActor
struct RestrictAndLimitsTests {
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
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )
    }

    /// Waits on STATE, not time: polls until `condition` holds and returns at
    /// once when it does, giving up after 2,000 looks (about 10 s on a free
    /// main actor).
    ///
    /// ⚠️ LOOKS, NOT A WALL-CLOCK DEADLINE. On CI the whole test process has
    /// frozen for two minutes (run 37318287644, #525): a 10 s deadline
    /// expired while this wait could not even run, and the one look left at
    /// the end came before the profile load had had its turn. A frozen
    /// process now costs no budget. A short budget that gave up silently made
    /// the next step a no-op (#521); the waits that matter are `#require`d.
    @discardableResult
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// The profile's menu restricts at once and confirms.
    @Test func theProfileMenuRestricts() async throws {
        let repository = makeRepository()
        let viewModel = ProfileViewModel(repository: repository, source: .profile(ProfileID("prof-3")))
        var results: [ProfileViewModel.ActionResult] = []
        viewModel.onActionResult = { results.append($0) }
        viewModel.viewDidLoad()
        // Both reads: the relationship can answer before the profile, and the
        // menu acts on a loaded profile only.
        try #require(await settle { viewModel.canModerate && viewModel.profile != nil }, "the profile never loaded")
        viewModel.toggleRestrict()
        #expect(viewModel.isRestricted, "optimistic")
        await settle { !results.isEmpty }
        guard case .restrictChanged(_, let restricted) = results.last else {
            Issue.record("no confirmation: \(results)")
            return
        }
        #expect(restricted)
        #expect(try await repository.isRestricted(ProfileID("prof-3")))
    }

    /// With an undo toast wired (#957), restricting is a deferred commit:
    /// Undo takes it back with nothing sent; the countdown running out sends it.
    @Test func restrictWithUndoIsSentOnlyOnCommit() async throws {
        let repository = makeRepository()
        let target = ProfileID("prof-3")
        let viewModel = ProfileViewModel(repository: repository, source: .profile(target))
        var pending: [UndoableAction] = []
        viewModel.onUndoable = { pending.append($0) }
        viewModel.viewDidLoad()
        try #require(await settle { viewModel.canModerate && viewModel.profile != nil }, "the profile never loaded")

        viewModel.toggleRestrict()
        #expect(viewModel.isRestricted)
        try #require(pending.count == 1)
        pending[0].undo()
        #expect(!viewModel.isRestricted)
        #expect(try await repository.isRestricted(target) == false, "sent before the countdown ran out")

        viewModel.toggleRestrict()
        try #require(pending.count == 2)
        pending[1].commit()
        var sent = false
        for _ in 0..<200 where !sent {
            sent = try await repository.isRestricted(target)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(sent)
        #expect(viewModel.isRestricted)
    }
}
