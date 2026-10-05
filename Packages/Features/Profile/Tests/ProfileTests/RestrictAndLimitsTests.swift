import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Restrict, temporary limits and sound reuse (#416; backend #724, #735,
/// #736), end to end over the mock BFF.
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

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Restrict reads back, lists hydrated, and leaves follows alone.
    @Test func restrictRoundTripsAndLists() async throws {
        let repository = makeRepository()
        let target = ProfileID("prof-3")
        let before = try await repository.followRelation(to: target)
        #expect(try await repository.isRestricted(target) == false)

        try await repository.setRestricted(true, for: target)
        #expect(try await repository.isRestricted(target))
        let listed = try await repository.restrictedProfiles()
        #expect(listed.map(\.id) == [target])
        #expect(listed.first?.handle != "prof-3")
        #expect(try await repository.followRelation(to: target) == before, "a restriction isn't a block")

        let viewModel = RestrictedAccountsViewModel(restricting: repository)
        await viewModel.load()
        guard case .loaded(let rows) = viewModel.phase, let row = rows.first else {
            Issue.record("the list didn't load")
            return
        }
        try await viewModel.unrestrict(row)
        #expect(try await repository.isRestricted(target) == false)
    }

    /// The profile's menu restricts at once and confirms.
    @Test func theProfileMenuRestricts() async throws {
        let repository = makeRepository()
        let viewModel = ProfileViewModel(repository: repository, source: .profile(ProfileID("prof-3")))
        var results: [ProfileViewModel.ActionResult] = []
        viewModel.onActionResult = { results.append($0) }
        viewModel.viewDidLoad()
        await settle { viewModel.canModerate }
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

    /// A limit sets, reads back and clears; past four weeks it's refused.
    @Test func aLimitSetsAndClears() async throws {
        let repository = makeRepository()
        #expect(try await repository.interactionLimit() == nil)

        let until = Date().addingTimeInterval(7 * 86_400)
        try await repository.setInteractionLimit(InteractionLimit(audience: .recentFollowers, until: until))
        let limit = try #require(try await repository.interactionLimit())
        #expect(limit.audience == .recentFollowers)
        #expect(abs(limit.until.timeIntervalSince(until)) < 1)

        await #expect(throws: (any Error).self) {
            try await repository.setInteractionLimit(InteractionLimit(audience: .nonFollowers, until: Date().addingTimeInterval(40 * 86_400)))
        }

        try await repository.clearInteractionLimit()
        #expect(try await repository.interactionLimit() == nil)
    }

    /// Sound reuse is on by default, sticks when off, and survives a change
    /// to who can comment (which sends the set without it).
    @Test func soundReuseSticks() async throws {
        let repository = makeRepository()
        #expect(try await repository.allowsSoundReuse())
        try await repository.setAllowsSoundReuse(false)
        #expect(try await repository.allowsSoundReuse() == false)
        try await repository.setCommentAudience(.followers)
        #expect(try await repository.allowsSoundReuse() == false)
    }

    @Test func theScreensReadPlainly() {
        #expect(LimitInteractionsViewController.durationTitle(days: 28) == "4 Weeks")
        #expect(InteractionLimit.durations.max() == InteractionLimit.maximumDays)
        #expect(RestrictedAccountsViewController.footer.contains("seen only by them and you"))
    }
}
