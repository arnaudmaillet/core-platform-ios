import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import DesignSystem
import Foundation
import Testing
@testable import Search

fileprivate actor StubProvider: SearchProviding {
    private let results: [ProfileSearchResult]

    init(results: [ProfileSearchResult]) { self.results = results }

    func searchProfiles(matching query: String, sort: SearchSortOrder, limit: Int32) async throws -> [ProfileSearchResult] { results }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
}

fileprivate actor StubMetadata: ProfileMetadataProviding {
    private let entries: [ProfileID: ProfileRowMetadata]

    init(_ entries: [ProfileID: ProfileRowMetadata]) { self.entries = entries }

    func metadata(for ids: [ProfileID]) async -> [ProfileID: ProfileRowMetadata] {
        entries.filter { ids.contains($0.key) }
    }
}

/// "Follow from Search → the profile header and the feed's '+' agree" (#896),
/// Search's half: the person rows hear the app's follow channel
/// (`FollowGraphEvents`) — the one the profile header (`ProfileViewModel`)
/// and the feeds' "+" (`EntityStore.follow`) hear — so a follow made on the
/// profile pushed from a result, or on a feed's "+", is on the row at once.
@MainActor
struct SearchFollowChannelTests {
    private let ada = ProfileID("prof-1")

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func lastResults(_ phases: [SearchViewModel.Phase]) -> [SearchResultDisplayModel] {
        for phase in phases.reversed() {
            if case .results(let models) = phase { return models }
        }
        return []
    }

    @Test func aFollowMadeOnTheProfileReachesTheSearchRowAndBack() async {
        let events = FollowGraphEvents()
        let viewModel = SearchViewModel(
            repository: StubProvider(results: [
                ProfileSearchResult(id: ada, handle: "ada", displayName: "Ada", isVerified: false)
            ]),
            metadata: StubMetadata([ada: ProfileRowMetadata(avatarURL: nil, isFollowed: false, followerCount: 120)]),
            suggestDebounce: .zero,
            followEvents: events
        )
        var phases: [SearchViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.submitQuery("ada")
        await settle(until: { lastResults(phases).first?.context == .followerCount(120) })
        #expect(lastResults(phases).first?.context == .followerCount(120))

        // Followed on the profile pushed from this result: the graph accepted.
        events.publish(FollowChange(profileID: ada, isFollowing: true))
        await settle(until: { lastResults(phases).first?.context == .following })
        #expect(lastResults(phases).first?.context == .following)

        // Unfollowed from a feed's card menu.
        events.publish(FollowChange(profileID: ada, isFollowing: false))
        await settle(until: { lastResults(phases).first?.context == .followerCount(120) })
        #expect(lastResults(phases).first?.context == .followerCount(120))
    }

    /// Someone else's follow moves nothing on this row.
    @Test func anotherPersonsFollowLeavesTheRow() async {
        let events = FollowGraphEvents()
        let viewModel = SearchViewModel(
            repository: StubProvider(results: [
                ProfileSearchResult(id: ada, handle: "ada", displayName: "Ada", isVerified: false)
            ]),
            metadata: StubMetadata([ada: ProfileRowMetadata(avatarURL: nil, isFollowed: false, followerCount: 120)]),
            suggestDebounce: .zero,
            followEvents: events
        )
        var phases: [SearchViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.submitQuery("ada")
        await settle(until: { lastResults(phases).first?.context == .followerCount(120) })
        let count = phases.count

        events.publish(FollowChange(profileID: ProfileID("prof-9"), isFollowing: true))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(phases.count == count)
        #expect(lastResults(phases).first?.context == .followerCount(120))
    }

    // MARK: - The session cache

    private func makeRepository() -> ProfileMetadataRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(dataset: dataset, isPrivate: { social.isPrivate($0) }).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileMetadataRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            viewerID: { ProfileID(MockSocialDataset.viewerProfileID) }
        )
    }

    /// The search screen's session cache hears the channel too: a search made
    /// after the follow, on a new screen, draws "Following" without asking the
    /// graph again — and a read still in flight answers with the follow.
    @Test func theSessionCacheKeepsAFollowMadeElsewhere() async throws {
        let repository = makeRepository()
        let first = await repository.metadata(for: [ada])
        let read = try #require(first[ada])

        await repository.applyFollowChange(FollowChange(profileID: ada, isFollowing: !read.isFollowed))

        #expect(await repository.debugCached(ada)?.isFollowed == !read.isFollowed)
        #expect(await repository.metadata(for: [ada])[ada]?.isFollowed == !read.isFollowed)
    }

    @Test func aFollowAcceptedBeforeTheReadLandsIsWhatTheReadAnswers() async {
        let repository = makeRepository()
        let target = ProfileID("prof-30")

        await repository.applyFollowChange(FollowChange(profileID: target, isFollowing: true))
        let answer = await repository.metadata(for: [target])

        // The read comes back after the follow: the follow is newer than
        // whatever the graph answered when it was asked.
        #expect(answer[target]?.isFollowed == true)
        await repository.applyFollowChange(FollowChange(profileID: target, isFollowing: false))
        #expect(await repository.metadata(for: [target])[target]?.isFollowed == false)
    }
}
