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

    /// The four sources added in #412 save one at a time too, each to its own
    /// field of `SetDiscoverySettings`.
    @Test func everySourceSavesOnItsOwn() async throws {
        let fixture = makeFixture()
        for key in [ActivityDiscoverySettings.Switch.findableByPhone, .findableByEmail, .reachableByLink, .inSuggestions] {
            try await fixture.repository.setActivityDiscovery(key, to: false)
            var expected = ActivityDiscoverySettings()
            expected[key] = false
            #expect(try await fixture.repository.activityDiscoverySettings() == expected)
            try await fixture.repository.setActivityDiscovery(key, to: true)
        }
        #expect(try await fixture.repository.activityDiscoverySettings() == ActivityDiscoverySettings())
    }

    /// The profile's token is issued once and stays; a reset gives a new one
    /// and the old link stops opening the profile at once (backend #661).
    @Test func resettingTheLinkRetiresTheOldOne() async throws {
        let fixture = makeFixture()
        let first = try await fixture.repository.shareToken()
        #expect(first.count == 22)
        #expect(try await fixture.repository.shareToken() == first, "issued once")
        #expect(try await resolve(first, in: fixture) == MockPostStore.viewer.profileID)

        let next = try await fixture.repository.rotateShareToken()
        #expect(next != first)
        #expect(try await fixture.repository.shareToken() == next)
        #expect(try await resolve(first, in: fixture) == nil, "the old link no longer works")
        #expect(try await resolve(next, in: fixture) == MockPostStore.viewer.profileID)
    }

    /// With "QR Code and Shared Links" off, the current token opens nothing;
    /// on again, it works (the token is kept).
    @Test func switchingLinksOffClosesThem() async throws {
        let fixture = makeFixture()
        let token = try await fixture.repository.shareToken()
        try await fixture.repository.setActivityDiscovery(.reachableByLink, to: false)
        #expect(try await resolve(token, in: fixture) == nil)
        try await fixture.repository.setActivityDiscovery(.reachableByLink, to: true)
        #expect(try await resolve(token, in: fixture) == MockPostStore.viewer.profileID)
        #expect(try await resolve(MockSocialServices.seededShareToken, in: fixture) == "prof-1")
    }

    /// The profile a token opens, or nil on NOT_FOUND.
    private func resolve(_ token: String, in fixture: Fixture) async throws -> String? {
        var request = Profile_V1_ResolveShareTokenRequest()
        request.token = token
        let response = await fixture.profileClient.resolveShareToken(request: request, headers: [:])
        if let view = response.message { return view.profileID }
        #expect(response.error?.code == .notFound)
        return nil
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
        #expect(ActivityDiscoveryViewController.title(.findableByPhone) == "Find Me by Phone Number")
        #expect(ActivityDiscoveryViewController.title(.reachableByLink) == "QR Code and Shared Links")
        #expect(ActivityDiscoveryViewController.discoverySwitches.count == 4)
        #expect(ActivityDiscoveryViewController.footer(.links).contains("stop working right away"))
    }
}
