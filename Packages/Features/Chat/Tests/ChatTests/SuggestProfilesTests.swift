import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Chat

// Messages → Suggestions reads social_graph's SuggestProfiles (#644).

private struct Viewer: ViewerIdentityProviding {
    func viewerProfileID() async throws -> ProfileID { ProfileID(MockSocialDataset.viewerProfileID) }
}

// MARK: - The repository, against the mock fleet

struct SuggestProfilesRepositoryTests {
    private func makeRepository(
        isPrivate: @escaping @Sendable (String) -> Bool = { _ in false },
        isSuggestible: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> (SocialConnectionsRepository, MockBFF) {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset, isPrivate: isPrivate, isSuggestible: isSuggestible).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = SocialConnectionsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            viewer: Viewer(),
            pageSize: 200
        )
        return (repository, bff)
    }

    /// One ranked call, one read of who follows the viewer — and none of
    /// the eight `ListFollowing` the client used to fan out to.
    @Test func suggestionsAreTheServersRankingWithNoFanOut() async throws {
        let (repository, bff) = makeRepository()

        let suggestions = try await repository.suggestions(limit: 20)

        try #require(!suggestions.isEmpty, "guard: the mock viewer has friends of friends")
        let paths = bff.recordedRequests.map(\.path)
        #expect(paths.filter { $0.hasSuffix("/SuggestProfiles") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/ListFollowing") }.isEmpty, "the fan-out is back: \(paths)")
        #expect(paths.filter { $0.hasSuffix("/ListFollowers") }.count <= 1)
        #expect(suggestions.count <= 20)
        #expect(Set(suggestions.map(\.id)).count == suggestions.count, "a profile twice")
        // Every row says why: it follows the viewer, or how many of the
        // viewer's follows follow it.
        for suggestion in suggestions {
            switch suggestion.reason {
            case .followsYou: break
            case .followedBy(let names, let total): #expect(names.isEmpty && total > 0, "\(suggestion.reason)")
            case .suggestedForYou: Issue.record("a friend of a friend with no mutuals: \(suggestion.id)")
            }
        }
    }

    /// What the server leaves out — a private profile, one that turned
    /// "appear in suggestions" off — never reaches the list.
    @Test func aProfileTheServerExcludesNeverAppears() async throws {
        let (baseline, _) = makeRepository()
        let all = try await baseline.suggestions(limit: 50).map(\.id.rawValue)
        try #require(all.count >= 3, "guard: enough suggestions to take two away")
        let hidden = all[0]
        let optedOut = all[1]

        let (repository, _) = makeRepository(
            isPrivate: { $0 == hidden },
            isSuggestible: { $0 != optedOut }
        )
        let shown = try await repository.suggestions(limit: 50).map(\.id.rawValue)

        #expect(!shown.contains(hidden), "a private profile was suggested")
        #expect(!shown.contains(optedOut), "a profile that opted out was suggested")
        #expect(shown == all.filter { $0 != hidden && $0 != optedOut }, "the rest moved")
    }

    /// The same graph answers the same order, so the whole list starts with
    /// the first page — what lets the view model ask for more without a
    /// cursor.
    @Test func theLongerListStartsWithTheShorterOne() async throws {
        let (repository, _) = makeRepository()

        let first = try await repository.suggestions(limit: 2).map(\.id)
        let whole = try await repository.suggestions(limit: 500).map(\.id)

        try #require(first.count == 2, "guard: the mock has more than one page")
        #expect(Array(whole.prefix(2)) == first)
        #expect(whole.count <= SocialConnectionsRepository.suggestionLimit)
    }

    /// A conversation's @handle (#752) comes from the same profile read as
    /// its face: one `GetProfileById` for both.
    @Test func theHandleAndTheFaceShareOneProfileRead() async throws {
        let (baseline, _) = makeRepository()
        let known = try #require(try await baseline.suggestions(limit: 1).first, "guard: a profile to read")

        let (repository, bff) = makeRepository()
        _ = await repository.avatarURLs(for: [known.id])
        let handles = await repository.handles(for: [known.id, ProfileID("nobody")])

        #expect(handles == [known.id: known.handle])
        let reads = bff.recordedRequests.map(\.path).filter { $0.hasSuffix("/GetProfileById") }
        #expect(reads.count == 2, "one read per profile, cached for the handle: \(reads)")
    }
}

// MARK: - The view model: a page, then the whole list

/// `count` ranked suggestions; answers a prefix, records every limit asked,
/// and can fail the next ask.
private actor RankedSuggestions: SuggestionsProviding {
    let count: Int
    private(set) var asked: [Int] = []
    var failsNext = false

    init(count: Int) { self.count = count }

    func failNext() { failsNext = true }

    func suggestions(limit: Int) async throws -> [SuggestedAccount] {
        asked.append(limit)
        if failsNext {
            failsNext = false
            throw SuggestionsError.transport(message: "down")
        }
        return (0..<min(limit, count)).map { index in
            SuggestedAccount(
                id: ProfileID("p\(index)"), handle: "p\(index)", displayName: "P \(index)",
                avatarURL: nil, reason: .followedBy(names: [], total: 1)
            )
        }
    }

    func follow(_ profileID: ProfileID) async throws {}
    func unfollow(_ profileID: ProfileID) async throws {}
}

@MainActor
struct SuggestionsPagingTests {
    /// Whether `condition` came to hold within `looks` looks — a budget of
    /// looks, not wall-clock time, so a starved runner spends none of it.
    private func settle(looks: Int = 2_000, until condition: () async -> Bool) async -> Bool {
        for _ in 0..<looks {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func rows(_ viewModel: SuggestionsViewModel) -> [String] {
        guard case .content(let models) = viewModel.phase else { return [] }
        return models.map(\.id.rawValue)
    }

    @Test func theEndOfTheListAsksOnceForTheWholeList() async throws {
        let source = RankedSuggestions(count: 60)
        let viewModel = SuggestionsViewModel(repository: source, limit: 20, fullLimit: 50)

        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 20 })
        #expect(viewModel.hasMore)

        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 50 })
        #expect(rows(viewModel) == (0..<50).map { "p\($0)" }, "the first page kept its place")
        #expect(!viewModel.hasMore, "the server gives no more than the whole list")

        viewModel.loadMore()
        for _ in 0..<50 { await Task.yield() }
        #expect(await source.asked == [20, 50])
    }

    /// A first page that came back short was the whole list already.
    @Test func aShortFirstPageHasNoMore() async throws {
        let source = RankedSuggestions(count: 7)
        let viewModel = SuggestionsViewModel(repository: source, limit: 20, fullLimit: 50)

        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 7 })
        viewModel.loadMore()
        for _ in 0..<50 { await Task.yield() }

        #expect(!viewModel.hasMore)
        #expect(await source.asked == [20])
    }

    /// Coming back to the page refreshes it — for as many rows as were
    /// held, so it never takes back what the viewer scrolled to.
    @Test func aRefreshAsksForAsManyAsAreHeld() async throws {
        let source = RankedSuggestions(count: 60)
        let viewModel = SuggestionsViewModel(repository: source, limit: 20, fullLimit: 50)
        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 20 })
        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 50 })

        viewModel.refresh()
        try #require(await settle { await source.asked.count == 3 })
        try #require(await settle { self.rows(viewModel).count == 50 })

        #expect(await source.asked == [20, 50, 50])
    }

    /// A failed ask at the end keeps the place: the next approach asks
    /// again.
    @Test func aFailedAskAtTheEndIsAskedAgain() async throws {
        let source = RankedSuggestions(count: 60)
        let viewModel = SuggestionsViewModel(repository: source, limit: 20, fullLimit: 50)
        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 20 })

        await source.failNext()
        viewModel.loadMore()
        try #require(await settle { await source.asked.count == 2 })
        for _ in 0..<50 { await Task.yield() }
        #expect(rows(viewModel).count == 20, "a failed ask took rows away")
        #expect(viewModel.hasMore)

        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 50 })
        #expect(await source.asked == [20, 50, 50])
    }
}
