import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Privacy → Activity and Discovery (#406, #412; backend #726,
/// #727), end to end over the mock BFF.
@MainActor
struct ActivityDiscoveryTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private struct Fixture {
        let repository: ProfileRepository
        let profileClient: Profile_V1_ProfileServiceClient
        let searchClient: Search_V1_SearchServiceClient
        let dataset: MockSocialDataset
    }

    private func makeFixture() -> Fixture {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        MockSearchService(dataset: dataset, isFindable: { social.isFindableInSearch($0) }).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let profileClient = Profile_V1_ProfileServiceClient(client: client)
        return Fixture(
            repository: ProfileRepository(
                profileClient: profileClient,
                counterClient: Counter_V1_CounterServiceClient(client: client),
                socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
                authSession: Session()
            ),
            profileClient: profileClient,
            searchClient: Search_V1_SearchServiceClient(client: client),
            dataset: dataset
        )
    }

    /// All on by default; one switch changes alone (a partial update).
    @Test func switchesChangeOneAtATime() async throws {
        let fixture = makeFixture()
        #expect(try await fixture.repository.activityDiscoverySettings() == ActivityDiscoverySettings())

        try await fixture.repository.setActivityDiscovery(.readReceipts, to: false)
        #expect(try await fixture.repository.activityDiscoverySettings()
            == ActivityDiscoverySettings(activityStatus: true, readReceipts: false, findableInSearch: true))

        try await fixture.repository.setActivityDiscovery(.activityStatus, to: false)
        try await fixture.repository.setActivityDiscovery(.readReceipts, to: true)
        #expect(try await fixture.repository.activityDiscoverySettings()
            == ActivityDiscoverySettings(activityStatus: false, readReceipts: true, findableInSearch: true))
    }

    /// A profile that turns off "Show Up in Search" leaves search and its
    /// suggestions, and comes back when it turns it on again.
    @Test func searchLeavesOutAProfileThatAsks() async throws {
        let fixture = makeFixture()
        let author = try #require(fixture.dataset.authors.first)
        var search = Search_V1_SearchRequest()
        search.query = author.handle
        search.entityTypes = [.profile]
        func found() async throws -> Bool {
            try await fixture.searchClient.search(request: search, headers: [:]).result.get().hits.map(\.id).contains(author.profileID)
        }
        #expect(try await found())

        var off = Profile_V1_SetDiscoverySettingsRequest()
        off.profileID = author.profileID
        off.byHandleSearch = false
        _ = try await fixture.profileClient.setDiscoverySettings(request: off, headers: [:]).result.get()
        #expect(try await !found())
        var suggest = Search_V1_SuggestRequest()
        suggest.prefix = author.handle
        #expect(try await !fixture.searchClient.suggest(request: suggest, headers: [:]).result.get().suggestions.map(\.id).contains(author.profileID))

        var on = off
        on.byHandleSearch = true
        _ = try await fixture.profileClient.setDiscoverySettings(request: on, headers: [:]).result.get()
        #expect(try await found())
    }

    @Test func theScreenSaysWhatEachSwitchDoes() {
        #expect(ActivityDiscoveryViewController.title(.findableInSearch) == "Show Up in Search")
        #expect(ActivityDiscoveryViewController.footer(.activity).contains("Read Receipts is off"))
        #expect(ActivityDiscoveryViewController.planned.contains("Find me by phone number"))
    }
}
