import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

private struct ShareTargetsSessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

/// Drives the ranking through the real wire path — repository → generated
/// clients → MockBFF — against the seeded graph.
///
/// Expectations are DERIVED from the dataset rather than hardcoded: the seed's
/// follow count has already been changed once (four → twelve, for the compose
/// picker's friend-of-friend expansion), and a test that restates it just
/// breaks the next time.
struct ProfileShareTargetsTests {
    private let dataset = MockSocialDataset()

    private func makeRepository() -> ProfileShareTargetsRepository {
        let dataset = dataset
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockSearchService(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)

        let profileRepository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: ShareTargetsSessionStub()
        )
        return ProfileShareTargetsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            searchClient: Search_V1_SearchServiceClient(client: client),
            viewer: profileRepository
        )
    }

    // MARK: - Search

    /// Search is the row's only route to someone the graph didn't suggest, so
    /// it must reach beyond the follow list — `prof-4` is deliberately NOT
    /// followed by the viewer in the seed.
    @Test func searchReachesProfilesOutsideTheFollowList() async {
        let repository = makeRepository()
        let handle = MockSocialDataset().authors[4].handle

        let results = await repository.searchTargets(query: handle, limit: 12)

        #expect(results.contains { $0.handle == handle })
    }

    @Test func searchHydratesResultsLikeSuggestions() async {
        let results = await makeRepository().searchTargets(query: "ava", limit: 12)

        let ava = results.first { $0.handle == "ava.moreau" }
        #expect(ava?.displayName == "Ava Moreau")
        #expect(ava?.avatarURL != nil)
    }

    /// You cannot send a profile to yourself, and your own face in a "send to"
    /// list reads as a bug.
    @Test func searchNeverReturnsTheViewer() async {
        let results = await makeRepository().searchTargets(query: "demo", limit: 12)

        #expect(!results.contains { $0.id.rawValue == MockSocialDataset.viewerProfileID })
    }

    @Test func blankQueriesReturnNothingRatherThanEverything() async {
        let repository = makeRepository()

        #expect(await repository.searchTargets(query: "", limit: 12).isEmpty)
        #expect(await repository.searchTargets(query: "   ", limit: 12).isEmpty)
    }

    @Test func searchWithoutAClientDegradesToEmpty() async {
        let bff = MockBFF()
        MockSocialGraphService(dataset: MockSocialDataset()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ProfileShareTargetsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            viewer: UnresolvableViewer()
        )

        #expect(await repository.searchTargets(query: "ava", limit: 12).isEmpty)
    }

    /// Mutuals lead. This is the whole ranking: someone who follows you back is
    /// the closest thing the client has to "a person you actually talk to".
    @Test func ranksMutualsAheadOfOneWayFollows() async {
        let mutual = dataset.mutualProfileIDs
        let oneWay = dataset.followedProfileIDs.subtracting(mutual)

        let targets = await makeRepository().shareTargets(limit: 50)

        let ids = targets.map(\.id.rawValue)
        #expect(Set(ids.prefix(mutual.count)) == mutual)
        #expect(Set(ids.dropFirst(mutual.count)) == oneWay)
        // Never the viewer: you cannot send a profile to yourself.
        #expect(!ids.contains(MockSocialDataset.viewerProfileID))
    }

    /// Hydration runs in a task group, which completes in arrival order — the
    /// results have to be put back into rank order afterwards or the row
    /// reshuffles between openings of the sheet.
    @Test func orderIsStableAcrossReads() async {
        let repository = makeRepository()

        let first = await repository.shareTargets(limit: 12).map(\.id)
        let second = await repository.shareTargets(limit: 12).map(\.id)

        #expect(first == second)
    }

    @Test func hydratesIdentityForEachTarget() async {
        let targets = await makeRepository().shareTargets(limit: 12)

        let ava = targets.first { $0.id == ProfileID("prof-0") }
        #expect(ava?.displayName == "Ava Moreau")
        #expect(ava?.handle == "ava.moreau")
        #expect(ava?.avatarURL != nil)
    }

    /// The cap applies to the RANKED list, so a limit smaller than the mutual
    /// set still returns mutuals — the row never fills up with one-way follows
    /// while closer contacts are dropped.
    @Test func honoursTheLimitAndKeepsTheClosestContacts() async {
        let targets = await makeRepository().shareTargets(limit: 2)

        #expect(targets.count == 2)
        #expect(Set(targets.map(\.id.rawValue)) == dataset.mutualProfileIDs)
    }

    @Test func returnsNothingWithoutAViewer() async {
        let bff = MockBFF()
        MockSocialGraphService(dataset: MockSocialDataset()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ProfileShareTargetsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            viewer: UnresolvableViewer()
        )

        #expect(await repository.shareTargets(limit: 12).isEmpty)
    }
}

private struct UnresolvableViewer: ProfileViewerResolving {
    func viewerProfileID() async -> ProfileID? { nil }
}
