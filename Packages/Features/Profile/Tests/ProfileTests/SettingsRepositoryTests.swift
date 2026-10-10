import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import DesignSystem
import Foundation
import Testing
@testable import Profile

/// The settings reads and writes on `ProfileRepository`, end to end over the
/// mock BFF with production wire bytes: private account (#388) and blocked
/// accounts (#389), both for the ACTIVE profile.
@MainActor
struct SettingsRepositoryTests {
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

    @Test func privateAccountRoundTripsForTheActiveProfileOnly() async throws {
        let repository = makeRepository()
        let profiles = try await repository.accountProfiles()
        await repository.setActiveProfile(profiles[1].id)
        let otherBefore = try await repository.activeProfileIsPrivate()

        await repository.setActiveProfile(profiles[0].id)
        #expect(try await repository.activeProfileIsPrivate() == false)
        try await repository.setActiveProfilePrivate(true)
        #expect(try await repository.activeProfileIsPrivate() == true)

        // Another profile on the account keeps its own setting.
        await repository.setActiveProfile(profiles[1].id)
        #expect(try await repository.activeProfileIsPrivate() == otherBefore)
    }

    @Test func aBlockAppearsHydratedAndUnblockingRemovesIt() async throws {
        let repository = makeRepository()
        #expect(try await repository.blockedProfiles().isEmpty)

        let target = ProfileID("prof-3")
        try await repository.setBlocked(true, for: target)
        let blocked = try await repository.blockedProfiles()
        #expect(blocked.map(\.id) == [target])
        #expect(blocked.first?.handle.isEmpty == false)
        #expect(blocked.first?.handle != "prof-3", "the row should carry the profile's handle, not its id")
        #expect(blocked.first?.blockedAt != nil)

        try await repository.unblock(target)
        #expect(try await repository.blockedProfiles().isEmpty)
    }

    @Test func newestBlockFirst() async throws {
        let repository = makeRepository()
        try await repository.setBlocked(true, for: ProfileID("prof-3"))
        try await Task.sleep(for: .milliseconds(20))
        try await repository.setBlocked(true, for: ProfileID("prof-4"))
        #expect(try await repository.blockedProfiles().map(\.id.rawValue) == ["prof-4", "prof-3"])
    }

    @Test func theMonogramPrefersTheNameThenTheHandle() {
        let named = BlockedProfile(id: ProfileID("a"), handle: "maya", displayName: "Maya Lopez", avatarURL: nil, blockedAt: nil)
        #expect(MonogramAvatarView.monogram(name: named.displayName, handle: named.handle) == "ML")
        let bare = BlockedProfile(id: ProfileID("b"), handle: "zed", displayName: " ", avatarURL: nil, blockedAt: nil)
        #expect(MonogramAvatarView.monogram(name: bare.displayName, handle: bare.handle) == "Z")
    }

    @Test func unblockingFromTheListDropsTheRow() async throws {
        let repository = makeRepository()
        try await repository.setBlocked(true, for: ProfileID("prof-3"))
        let model = BlockedAccountsViewModel(blocks: repository)
        await model.load()
        guard case .loaded(let rows) = model.phase, let row = rows.first else { Issue.record("no rows"); return }
        try await model.unblock(row)
        #expect(model.phase == .loaded([]))
    }
}
