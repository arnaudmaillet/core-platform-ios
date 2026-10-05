import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Edit Profile → Account Type (#415, backend #734), end to end over the mock.
@MainActor
struct AccountTypeTests {
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

    /// Done when: a creator account shows its type — on the profile model
    /// every surface reads, not only in settings.
    @Test func aCreatorShowsItsType() async throws {
        let repository = makeRepository()
        #expect(try await repository.accountType().type == .personal)

        try await repository.setAccountType(.creator, contact: nil)
        #expect(try await repository.accountType().type == .creator)
        let profile = try await repository.currentUserProfile()
        #expect(profile.accountType == .creator)
        #expect(ProfileDisplayModel(profile: profile).handleLine == "@\(profile.handle) · Creator")

        // Another author seeded as a creator reads as one too.
        #expect(try await repository.profile(id: ProfileID("prof-6")).accountType == .creator)
    }

    /// A business needs a category and shows it; switching away drops the card.
    @Test func aBusinessCarriesItsCardUntilItSwitchesAway() async throws {
        let repository = makeRepository()
        await #expect(throws: AccountTypeError.self) {
            try await repository.setAccountType(.business, contact: BusinessContact(category: "  "))
        }

        try await repository.setAccountType(.business, contact: BusinessContact(category: "Bakery", email: "hi@bakery.example"))
        let business = try await repository.accountType()
        #expect(business.type == .business)
        #expect(business.contact == BusinessContact(category: "Bakery", email: "hi@bakery.example"))
        let profile = try await repository.currentUserProfile()
        #expect(ProfileDisplayModel(profile: profile).handleLine == "@\(profile.handle) · Bakery")

        try await repository.setAccountType(.personal, contact: nil)
        let personal = try await repository.accountType()
        #expect(personal.type == .personal)
        #expect(personal.contact == nil)
        #expect(ProfileDisplayModel(profile: try await repository.currentUserProfile()).handleLine == "@\(profile.handle)")
    }

    @Test func theChoicesReadPlainly() {
        #expect(AccountType.choices.map(\.title) == ["Personal", "Creator", "Business"])
        #expect(!BusinessContact(category: String(repeating: "a", count: 65)).isValid)
        #expect(AccountTypeViewController.footer(.type, type: .bot) == AccountType.bot.detail)
    }
}
