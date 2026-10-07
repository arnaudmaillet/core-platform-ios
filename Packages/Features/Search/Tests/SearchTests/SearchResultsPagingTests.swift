import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Search

// The search results, page by page (#612).

/// Serves people and post pages by (query, token), records every ask, and
/// can hold a token until released — to land a page after a newer search.
private actor PagedSearch: SearchProviding {
    struct Ask: Equatable {
        let kind: String
        let query: String
        let token: String?
        let limit: Int32
    }

    private let people: [String: [String?: ProfileSearchPage]]
    private let posts: [String: [String?: PostSearchPage]]
    private(set) var asks: [Ask] = []
    private var held: Set<String> = []
    private var heldWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(people: [String: [String?: ProfileSearchPage]], posts: [String: [String?: PostSearchPage]] = [:]) {
        self.people = people
        self.posts = posts
    }

    func hold(_ token: String) { held.insert(token) }
    func release(_ token: String) {
        held.remove(token)
        for waiter in heldWaiters.removeValue(forKey: token) ?? [] { waiter.resume() }
    }
    func asks(_ kind: String) -> [String?] { asks.filter { $0.kind == kind }.map(\.token) }

    private func waitIfHeld(_ token: String?) async {
        guard let token, held.contains(token) else { return }
        await withCheckedContinuation { heldWaiters[token, default: []].append($0) }
    }

    func searchProfiles(matching query: String, sort: SearchSortOrder, limit: Int32) async throws -> [ProfileSearchResult] {
        try await searchProfilesPage(matching: query, sort: sort, limit: limit, pageToken: nil).results
    }

    func searchProfilesPage(
        matching query: String, sort: SearchSortOrder, limit: Int32, pageToken: String?
    ) async throws -> ProfileSearchPage {
        asks.append(Ask(kind: "people", query: query, token: pageToken, limit: limit))
        await waitIfHeld(pageToken)
        return people[query]?[pageToken] ?? ProfileSearchPage(results: [], nextPageToken: nil)
    }

    func searchPostsPage(
        matching query: String, sort: SearchSortOrder, limit: Int32, pageToken: String?
    ) async throws -> PostSearchPage {
        asks.append(Ask(kind: "posts", query: query, token: pageToken, limit: limit))
        await waitIfHeld(pageToken)
        return posts[query]?[pageToken] ?? PostSearchPage(hits: [], nextPageToken: nil)
    }

    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
}

private func person(_ number: Int) -> ProfileSearchResult {
    ProfileSearchResult(id: ProfileID("prof-\(number)"), handle: "user\(number)", displayName: "User \(number)", isVerified: false)
}

private func people(_ numbers: ClosedRange<Int>, next: String?) -> ProfileSearchPage {
    ProfileSearchPage(results: numbers.map(person), nextPageToken: next)
}

/// Even numbers have a picture, odd ones are text.
private func posts(_ numbers: [Int], next: String?) -> PostSearchPage {
    PostSearchPage(hits: numbers.map { PostSearchHit(id: PostID("post-\($0)"), hasMedia: $0.isMultiple(of: 2)) }, nextPageToken: next)
}

@MainActor
struct SearchResultsPagingTests {
    /// Whether `condition` came to hold within `looks` looks — a budget of
    /// looks, not wall-clock time, so a starved runner spends none of it.
    private func settle(looks: Int = 3_000, until condition: () async -> Bool) async -> Bool {
        for _ in 0..<looks {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func idle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func makeViewModel(_ provider: PagedSearch) -> SearchViewModel {
        SearchViewModel(
            repository: provider,
            recentSearches: RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 }),
            pageSize: 2
        )
    }

    private func handles(_ viewModel: SearchViewModel) -> [String] {
        guard case .results(let models) = viewModel.currentPhase else { return [] }
        return models.map { String($0.handle.dropFirst()) }
    }

    private func ids(_ posts: [PostID]) -> [String] { posts.map(\.rawValue) }

    @Test func nearingTheEndOfUsersAppendsTheNextPageOnceAndStopsAtTheEnd() async throws {
        let provider = PagedSearch(people: ["ann": [
            nil: people(1...2, next: "u2"),
            "u2": people(3...4, next: nil),
        ]])
        let viewModel = makeViewModel(provider)
        var paging: [Bool] = []
        viewModel.onPeoplePagingChange = { paging.append($0) }
        viewModel.submitQuery("ann")
        try #require(await settle { handles(viewModel) == ["user1", "user2"] })
        #expect(viewModel.hasMorePeople)

        viewModel.loadMorePeople()
        viewModel.loadMorePeople() // the same approach, reported twice
        try #require(await settle { handles(viewModel).count == 4 })

        #expect(handles(viewModel) == ["user1", "user2", "user3", "user4"])
        #expect(!viewModel.hasMorePeople)
        #expect(paging == [true, false])
        viewModel.loadMorePeople() // the end: nothing left to ask
        await idle()
        #expect(await provider.asks("people") == [nil, "u2"])
        // Every ask carries the page size.
        #expect(await provider.asks.allSatisfy { $0.limit == 2 })
    }

    /// A person already shown — they slid across the boundary — is not shown
    /// twice, and a page of nobody new walks on to the next.
    @Test func aPersonAlreadyShownIsNotShownTwice() async throws {
        let provider = PagedSearch(people: ["ann": [
            nil: people(1...2, next: "u2"),
            "u2": people(2...2, next: "u3"),
            "u3": people(2...3, next: nil),
        ]])
        let viewModel = makeViewModel(provider)
        viewModel.submitQuery("ann")
        try #require(await settle { handles(viewModel).count == 2 })

        viewModel.loadMorePeople()
        try #require(await settle { !viewModel.hasMorePeople && handles(viewModel).count == 3 })
        #expect(handles(viewModel) == ["user1", "user2", "user3"])
        #expect(await provider.asks("people") == [nil, "u2", "u3"])
    }

    /// Posts page into the Posts tab; the Media tab gets the new hits with a
    /// picture. Media's near-end reads on past a page of text posts.
    @Test func postsPageIntoBothTabsAndMediaReadsOnToAPicture() async throws {
        let provider = PagedSearch(
            people: ["ann": [nil: people(1...1, next: nil)]],
            posts: ["ann": [
                nil: posts([0, 1], next: "p2"),
                "p2": posts([3, 5], next: "p3"),
                "p3": posts([6, 7], next: nil),
            ]]
        )
        let viewModel = makeViewModel(provider)
        viewModel.submitQuery("ann")
        try #require(await settle { viewModel.postResults.count == 2 })
        #expect(ids(viewModel.mediaResults) == ["post-0"])
        #expect(viewModel.hasMorePosts)

        viewModel.loadMorePosts(untilMedia: true)
        try #require(await settle { !viewModel.hasMorePosts })

        #expect(ids(viewModel.postResults) == ["post-0", "post-1", "post-3", "post-5", "post-6", "post-7"])
        #expect(ids(viewModel.mediaResults) == ["post-0", "post-6"])
        #expect(await provider.asks("posts") == [nil, "p2", "p3"])
    }

    /// The Posts tab's near-end takes one page: text posts are rows there.
    @Test func thePostsTabTakesOnePageAtATime() async throws {
        let provider = PagedSearch(
            people: ["ann": [nil: people(1...1, next: nil)]],
            posts: ["ann": [
                nil: posts([0, 1], next: "p2"),
                "p2": posts([3, 5], next: "p3"),
            ]]
        )
        let viewModel = makeViewModel(provider)
        viewModel.submitQuery("ann")
        try #require(await settle { viewModel.postResults.count == 2 })

        viewModel.loadMorePosts()
        try #require(await settle { viewModel.postResults.count == 4 })
        await idle()
        #expect(await provider.asks("posts") == [nil, "p2"])
        #expect(viewModel.hasMorePosts)
    }

    /// A page for a superseded query never lands on the new query's results,
    /// and the new query starts from its own first page.
    @Test func aPageForASupersededQueryNeverLands() async throws {
        let provider = PagedSearch(people: [
            "ann": [nil: people(1...2, next: "u2"), "u2": people(3...4, next: nil)],
            "bob": [nil: people(10...11, next: "b2")],
        ])
        await provider.hold("u2")
        let viewModel = makeViewModel(provider)
        viewModel.submitQuery("ann")
        try #require(await settle { handles(viewModel).count == 2 })

        viewModel.loadMorePeople()
        try #require(await settle { await provider.asks("people").count == 2 })
        viewModel.submitQuery("bob")
        try #require(await settle { handles(viewModel) == ["user10", "user11"] })
        await provider.release("u2")
        await idle()

        #expect(handles(viewModel) == ["user10", "user11"])
        #expect(viewModel.hasMorePeople) // bob's own cursor, b2
    }

    /// Over the wire: the mock pages people and posts, and the pages add up
    /// to the whole answer, in order.
    @Test func theMockPagesPeopleAndPostsAcrossABoundary() async throws {
        let bff = MockBFF()
        MockSearchService(dataset: MockSocialDataset()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = SearchRepository(searchClient: Search_V1_SearchServiceClient(client: client))

        let everyone = try await repository.searchProfilesPage(matching: "a", sort: .relevance, limit: 500, pageToken: nil)
        #expect(everyone.nextPageToken == nil)
        #expect(everyone.results.count > 3)
        var paged: [ProfileSearchResult] = []
        var token: String?
        var pages = 0
        repeat {
            let page = try await repository.searchProfilesPage(matching: "a", sort: .relevance, limit: 3, pageToken: token)
            #expect(page.results.count <= 3)
            paged += page.results
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 50
        #expect(pages >= 2)
        #expect(paged.map(\.id) == everyone.results.map(\.id))

        let firstPosts = try await repository.searchPostsPage(matching: "a", sort: .relevance, limit: 3, pageToken: nil)
        #expect(firstPosts.hits.count == 3)
        let token2 = try #require(firstPosts.nextPageToken)
        let secondPosts = try await repository.searchPostsPage(matching: "a", sort: .relevance, limit: 3, pageToken: token2)
        #expect(Set(secondPosts.hits.map(\.id)).isDisjoint(with: firstPosts.hits.map(\.id)))
    }
}
