import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import MediaCore
import Testing
import UIKit
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
    /// How many first-page asks of each kind still fail (#798).
    private var failuresLeft: [String: Int] = [:]
    /// Why those asks fail, by kind (#794); none throws a plain error.
    private var failures: [String: NetworkFailure] = [:]
    private var heldWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(people: [String: [String?: ProfileSearchPage]], posts: [String: [String?: PostSearchPage]] = [:]) {
        self.people = people
        self.posts = posts
    }

    func hold(_ token: String) { held.insert(token) }
    /// The next first-page ask of `kind` ("people" / "posts") fails.
    func failOnce(_ kind: String) { failuresLeft[kind] = 1 }
    /// The next first-page ask of `kind` fails for `failure` (#794).
    func failOnce(_ kind: String, for failure: NetworkFailure) {
        failuresLeft[kind] = 1
        failures[kind] = failure
    }

    private func failIfAsked(_ kind: String, token: String?) throws {
        guard token == nil, let left = failuresLeft[kind], left > 0 else { return }
        failuresLeft[kind] = left - 1
        if let failure = failures[kind] { throw SearchError.transport(message: "x", failure: failure) }
        throw SearchFailure()
    }
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
        try failIfAsked("people", token: pageToken)
        return people[query]?[pageToken] ?? ProfileSearchPage(results: [], nextPageToken: nil)
    }

    func searchPostsPage(
        matching query: String, sort: SearchSortOrder, limit: Int32, pageToken: String?
    ) async throws -> PostSearchPage {
        asks.append(Ask(kind: "posts", query: query, token: pageToken, limit: limit))
        await waitIfHeld(pageToken)
        try failIfAsked("posts", token: pageToken)
        return posts[query]?[pageToken] ?? PostSearchPage(hits: [], nextPageToken: nil)
    }

    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
}

private struct SearchFailure: Error {}

private func person(_ number: Int) -> ProfileSearchResult {
    ProfileSearchResult(id: ProfileID("prof-\(number)"), handle: "user\(number)", displayName: "User \(number)", isVerified: false)
}

private func people(_ numbers: ClosedRange<Int>, next: String?) -> ProfileSearchPage {
    ProfileSearchPage(results: numbers.map(person), nextPageToken: next)
}

/// Even numbers have a picture, odd ones are text.
private func posts(_ numbers: [Int], next: String?) -> PostSearchPage {
    PostSearchPage(hits: numbers.map { PostSearchHit(id: PostID("post-\($0)")) }, nextPageToken: next)
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

    /// Posts page into the one Posts tab (#630), every hit, text posts
    /// included — a page of them is a page like any other.
    @Test func postsPageInEveryHit() async throws {
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
        #expect(viewModel.hasMorePosts)

        viewModel.loadMorePosts()
        try #require(await settle { viewModel.postResults.count == 4 })
        #expect(ids(viewModel.postResults) == ["post-0", "post-1", "post-3", "post-5"], "one page per ask")
        viewModel.loadMorePosts()
        try #require(await settle { !viewModel.hasMorePosts })

        #expect(ids(viewModel.postResults) == ["post-0", "post-1", "post-3", "post-5", "post-6", "post-7"])
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

    /// A search that failed offline says so on both tabs; a server fault
    /// keeps each tab's own words (#794).
    @Test(arguments: [
        (NetworkFailure.offline, FailureCopy.offline, FailureCopy.offline),
        (NetworkFailure.server(code: "unavailable"), "Couldn't search. Please try again.", "Couldn't search posts."),
    ])
    func aFailedSearchIsWordedByWhyItFailed(failure: NetworkFailure, people: String, posts: String) async throws {
        let provider = PagedSearch(people: ["ann": [:]], posts: ["ann": [:]])
        await provider.failOnce("people", for: failure)
        await provider.failOnce("posts", for: failure)
        let viewModel = makeViewModel(provider)
        viewModel.submitQuery("ann")
        try #require(await settle {
            if case .failed = viewModel.currentPhase { viewModel.postsFailed } else { false }
        })

        #expect(viewModel.currentPhase == .failed(message: people))
        #expect(viewModel.postsFailureText == posts)
    }

    /// #798: a post search that FAILED is not one that matched nothing — the
    /// Posts tab is told it failed, and Try Again re-asks for the posts alone,
    /// leaving the people answer as it is.
    @Test func aFailedPostSearchIsAFailureNotNoPostsAndTryAgainReasksForThePosts() async throws {
        let provider = PagedSearch(
            people: ["ann": [nil: people(1...1, next: nil)]],
            posts: ["ann": [nil: posts([0, 1], next: nil)]]
        )
        await provider.failOnce("posts")
        let viewModel = makeViewModel(provider)
        var announced = 0
        viewModel.onPostResultsChange = { _ in announced += 1 }
        viewModel.submitQuery("ann")
        try #require(await settle { viewModel.postsFailed && handles(viewModel) == ["user1"] })

        #expect(viewModel.postResults.isEmpty)
        #expect(!viewModel.isSearchingPosts)
        let announcedBeforeRetry = announced

        viewModel.retryFailedSearch()
        viewModel.retryFailedSearch() // a second tap while the first is out
        #expect(viewModel.isSearchingPosts, "the Posts tab goes back to loading")
        #expect(!viewModel.postsFailed)
        #expect(announced > announcedBeforeRetry, "and is told so")
        try #require(await settle { viewModel.postResults.count == 2 })

        #expect(ids(viewModel.postResults) == ["post-0", "post-1"])
        #expect(!viewModel.postsFailed)
        #expect(await provider.asks("posts") == [nil, nil])
        #expect(await provider.asks("people") == [nil], "the people answer was fine")
        #expect(handles(viewModel) == ["user1"])
    }

    /// #798: the people search failing fails the whole answer, and its Try
    /// Again runs the whole search again.
    @Test func aFailedPeopleSearchIsRetriedWhole() async throws {
        let provider = PagedSearch(people: ["ann": [nil: people(1...2, next: nil)]])
        await provider.failOnce("people")
        let viewModel = makeViewModel(provider)
        viewModel.submitQuery("ann")
        try #require(await settle {
            if case .failed = viewModel.currentPhase { true } else { false }
        })

        viewModel.retryFailedSearch()
        try #require(await settle { handles(viewModel) == ["user1", "user2"] })
        #expect(await provider.asks("people") == [nil, nil])
    }

    /// #798: a pull over good posts re-asks for the posts alone, and keeps
    /// them on the tab while it is out — and when it fails.
    @Test func aPullOverGoodPostsReasksForThemAndKeepsThemShown() async throws {
        let provider = PagedSearch(
            people: ["ann": [nil: people(1...1, next: nil)]],
            posts: ["ann": [nil: posts([0], next: nil)]]
        )
        let viewModel = makeViewModel(provider)
        viewModel.submitQuery("ann")
        try #require(await settle { viewModel.postResults.count == 1 && handles(viewModel) == ["user1"] })

        await provider.failOnce("posts")
        viewModel.retryFailedSearch()
        #expect(viewModel.isSearchingPosts)
        #expect(ids(viewModel.postResults) == ["post-0"], "still shown while the pull is out")
        try #require(await settle { !viewModel.isSearchingPosts })

        #expect(!viewModel.postsFailed, "a failed pull over posts keeps them")
        #expect(ids(viewModel.postResults) == ["post-0"])
        #expect(await provider.asks("posts") == [nil, nil])
        #expect(await provider.asks("people") == [nil], "the people answer is not asked again")
        #expect(handles(viewModel) == ["user1"])
    }

    /// #798: a failure clears the previous answer's rows, as an empty answer
    /// does — left under the message, they read as this query's results.
    @Test func theUsersTabsFailureClearsThePreviousRows() {
        let page = SearchPeoplePage(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        page.loadViewIfNeeded()
        page.render(.results([
            SearchResultDisplayModel(result: person(1)),
            SearchResultDisplayModel(result: person(2)),
        ]))
        #expect(page.rowCountForTesting == 2)

        page.render(.failed(message: "Couldn't search. Please try again."))

        #expect(page.rowCountForTesting == 0)
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
