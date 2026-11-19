import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import ProfileData
@testable import Settings

/// Mute (#403, backend #722), end to end over the mock BFF: the scopes, a
/// post menu's mute and block, and Settings → Safety → Muted Accounts. The
/// profile menu's toggles are the profile's `MuteTests`.
@MainActor
struct MutedAccountsTests {
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

    /// A post menu's Mute (#1498 §3) is the POSTS scope alone: their
    /// stories and messages keep whatever mute they had, and the undo lifts
    /// the posts only.
    @Test func aPostMenusMuteTouchesThePostsScopeOnly() async throws {
        let repository = makeRepository()
        let target = ProfileID("prof-3")
        try await repository.setMuteScopes(MuteScopes(messages: true), for: target)

        try await repository.setPostsMuted(true, for: target)
        #expect(try await repository.muteScopes(for: target) == MuteScopes(posts: true, messages: true))

        try await repository.setPostsMuted(false, for: target)
        #expect(try await repository.muteScopes(for: target) == MuteScopes(messages: true))
    }

    /// A post menu's Block of one profile blocks it, and names it.
    @Test func aPostMenusBlockBlocksTheProfile() async throws {
        let repository = makeRepository()
        let target = ProfileID("prof-4")
        #expect(try await repository.block(target, wholeAccount: false) == [target])
        #expect(try await repository.followRelation(to: target) == .blocked)
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

    @Test func theMutedListReadsPlainly() {
        #expect(MutedAccountsViewController.footer.contains("aren't told"))
    }
}
