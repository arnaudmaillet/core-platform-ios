import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Search

/// One `#tag`'s screen, its data, and the ways in (#524).
private actor TagSearch: SearchProviding {
    var top: [PostSearchHit] = []
    var recent: [PostSearchHit] = []
    var count: Int?
    var fails = false
    /// Fails every page after the first — a next page that does not arrive.
    var failsNextPages = false
    private(set) var queries: [String] = []
    /// Every page token asked for, in order (nil for a first page).
    private(set) var tokens: [String?] = []

    init(top: [PostSearchHit] = [], recent: [PostSearchHit] = [], count: Int? = nil, fails: Bool = false) {
        self.top = top
        self.recent = recent
        self.count = count
        self.fails = fails
    }

    func setFailsNextPages(_ fails: Bool) { failsNextPages = fails }

    func searchProfiles(matching query: String, sort: SearchSortOrder, limit: Int32) async throws -> [ProfileSearchResult] { [] }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
    func hashtagPostCount(_ tag: String) async throws -> Int? { count }

    /// Pages `limit` at a time; the token is the offset of the next page.
    func searchPostsPage(
        matching query: String, sort: SearchSortOrder, limit: Int32, pageToken: String?
    ) async throws -> PostSearchPage {
        queries.append(query)
        tokens.append(pageToken)
        if fails || (failsNextPages && pageToken != nil) { throw SearchError.transport(message: "offline") }
        let all = sort == .popularity ? top : recent
        let start = pageToken.flatMap(Int.init) ?? 0
        let end = min(start + Int(limit), all.count)
        return PostSearchPage(
            hits: start < end ? Array(all[start..<end]) : [],
            nextPageToken: end < all.count ? String(end) : nil
        )
    }
}

private func hits(_ count: Int, prefix: String = "p", media: Bool = true) -> [PostSearchHit] {
    (0..<count).map { PostSearchHit(id: PostID("\(prefix)\($0)"), hasMedia: media) }
}

@MainActor
private final class Routes: Router {
    private(set) var all: [AppRoute] = []
    func route(to route: AppRoute) { all.append(route) }
}

private func hit(_ id: String, media: Bool = true) -> PostSearchHit {
    PostSearchHit(id: PostID(id), hasMedia: media)
}

@MainActor
struct HashtagViewModelTests {
    @Test func topIsThePicturesRecentIsEverything() async {
        let search = TagSearch(top: [hit("a"), hit("t", media: false), hit("b")], recent: [hit("t", media: false), hit("a")])
        let viewModel = HashtagViewModel(tag: "#Travel", repository: search)
        await viewModel.load()

        #expect(viewModel.title == "#travel")
        #expect(viewModel.top == .posts([PostID("a"), PostID("b")]))
        #expect(viewModel.recent == .posts([PostID("t"), PostID("a")]))
        #expect(await search.queries.count == 2)
        #expect(await search.queries.allSatisfy { $0 == "#travel" }, "the tag is asked for with its #")
    }

    /// A first page that is not full is every post there is; a full one
    /// leaves the count to the index.
    @Test func theCountIsThePageWhenItIsAllThereIs() async {
        let small = HashtagViewModel(tag: "travel", repository: TagSearch(recent: [hit("a"), hit("b")], count: 40))
        await small.load()
        #expect(small.countText == "2 posts")

        let more = hits(Int(HashtagViewModel.pageSize) + 5)
        let big = HashtagViewModel(tag: "travel", repository: TagSearch(recent: more, count: 1_500))
        await big.load()
        #expect(big.countText == "1.5K posts")

        let one = HashtagViewModel(tag: "travel", repository: TagSearch(recent: [hit("a")]))
        await one.load()
        #expect(one.countText == "1 post")
    }

    // MARK: Paging (#579)

    private var page: Int { Int(HashtagViewModel.pageSize) }

    /// The first request asks for a page; each next one sends the token of
    /// the page before, appends, and nothing is asked once there is no more.
    @Test func recentLoadsPageByPageAndStops() async {
        let all = hits(page * 2 + 4)
        let search = TagSearch(recent: all)
        let viewModel = HashtagViewModel(tag: "travel", repository: search)
        await viewModel.load()
        #expect(viewModel.recent == .posts(Array(all.prefix(page)).map(\.id)))

        await viewModel.loadMore(.recent)
        #expect(viewModel.recent == .posts(Array(all.prefix(page * 2)).map(\.id)), "appended, in order")
        await viewModel.loadMore(.recent)
        #expect(viewModel.recent == .posts(all.map(\.id)))
        await viewModel.loadMore(.recent)

        let recentTokens = await search.tokens.filter { $0 != nil }
        #expect(recentTokens == [String(page), String(page * 2)], "each page from the last one's token, then no more")
    }

    /// Two approaches to the end while a page is on its way ask once.
    @Test func oneNextPageAtATime() async {
        let search = TagSearch(recent: hits(page * 3))
        let viewModel = HashtagViewModel(tag: "travel", repository: search)
        await viewModel.load()
        async let first: Void = viewModel.loadMore(.recent)
        async let second: Void = viewModel.loadMore(.recent)
        _ = await (first, second)
        #expect(await search.tokens.filter { $0 != nil } == [String(page)])
    }

    /// A next page that fails keeps what is shown, and the next approach to
    /// the end asks again.
    @Test func aFailedNextPageKeepsThePostsAndIsRetried() async {
        let all = hits(page * 2)
        let search = TagSearch(recent: all)
        let viewModel = HashtagViewModel(tag: "travel", repository: search)
        await viewModel.load()
        await search.setFailsNextPages(true)
        await viewModel.loadMore(.recent)
        #expect(viewModel.recent == .posts(Array(all.prefix(page)).map(\.id)))
        #expect(!viewModel.isLoadingMore(.recent))

        await search.setFailsNextPages(false)
        await viewModel.loadMore(.recent)
        #expect(viewModel.recent == .posts(all.map(\.id)))
    }

    /// Top shows pictures only: a page of text posts adds nothing, so it
    /// reads on rather than leave the viewer at an end that does not move.
    @Test func topReadsPastAPageOfTextPosts() async {
        let text = hits(page, prefix: "t", media: false)
        let pictures = hits(4, prefix: "m")
        let search = TagSearch(top: text + pictures)
        let viewModel = HashtagViewModel(tag: "travel", repository: search)
        await viewModel.load()
        #expect(viewModel.top == .posts(pictures.map(\.id)))
    }

    @Test func nothingTaggedIsEmptyAndAFailureSaysSo() async {
        let empty = HashtagViewModel(tag: "nothing", repository: TagSearch())
        await empty.load()
        #expect(empty.top == .empty(query: "#nothing"))
        #expect(empty.recent == .empty(query: "#nothing"))

        let offline = HashtagViewModel(tag: "travel", repository: TagSearch(fails: true))
        await offline.load()
        guard case .failed = offline.top, case .failed = offline.recent else {
            Issue.record("a failed search should say so on both pages")
            return
        }
    }
}

/// The repository against the mock world: tags are whole words of captions.
struct HashtagRepositoryTests {
    private func repository() -> SearchRepository {
        let backend = MockBackend()
        return SearchRepository(searchClient: Search_V1_SearchServiceClient(client: backend.makeRPCClient()))
    }

    @Test func aTagsPostsAreTheOnesCarryingIt() async throws {
        let dataset = MockSocialDataset()
        let tagged = dataset.posts.filter { $0.caption.lowercased().contains("#travel") }
        #expect(!tagged.isEmpty, "the mock corpus carries #travel")

        let recent = try await repository().searchPosts(matching: "#travel", sort: .recency, limit: 200)
        #expect(Set(recent.map(\.id)) == Set(tagged.map { PostID($0.postID) }))
        let stamps = recent.compactMap { hit in tagged.first { $0.postID == hit.id.rawValue }?.publishedAtMS }
        #expect(stamps == stamps.sorted(by: >), "Recent is newest first")

        #expect(try await repository().hashtagPostCount("travel") == tagged.count)
        #expect(try await repository().hashtagPostCount("nosuchtag") == nil)
    }

    /// The mock pages as the fleet does (#579): a page size, a token for the
    /// rest, every tagged post once across the pages, none past the end.
    @Test func aTagsPostsComePageByPage() async throws {
        let tagged = Set(MockSocialDataset().posts
            .filter { $0.caption.lowercased().contains("#travel") }
            .map { PostID($0.postID) })
        let repository = repository()
        var seen: [PostID] = []
        var token: String?
        var pages = 0
        repeat {
            let page = try await repository.searchPostsPage(matching: "#travel", sort: .recency, limit: 10, pageToken: token)
            #expect(page.hits.count <= 10)
            seen += page.hits.map(\.id)
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 20
        #expect(pages >= 2, "the corpus needs more than one page of #travel")
        #expect(seen.count == Set(seen).count, "no post twice")
        #expect(Set(seen) == tagged)
    }

    @Test func aHashSuggestsTags() async throws {
        let suggestions = try await repository().suggestions(forPrefix: "#tra", limit: 5)
        #expect(suggestions.map(\.text) == ["travel"])
        #expect(suggestions.allSatisfy { $0.kind == .hashtag })
    }
}

@MainActor
struct HashtagEntryTests {
    private func viewModel(_ routes: Routes) -> SearchViewModel {
        SearchViewModel(
            repository: TagSearch(),
            router: routes,
            recentSearches: RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 })
        )
    }

    @Test func searchingOneTagOpensIt() {
        let routes = Routes()
        let search = viewModel(routes)
        search.submitQuery("  #Travel ")
        #expect(routes.all == [.hashtag("travel")])

        search.submitQuery("#travel tips")
        #expect(routes.all == [.hashtag("travel")], "a tag in a longer query is still a query")
    }

    @Test func aHashtagCompletionOpensItsTag() {
        let row = SearchRowDisplayModel(suggestion: SearchSuggestion(text: "travel", kind: .hashtag, id: ""))
        #expect(row.text == "#travel")
        #expect(row.action == .openHashtag("travel"))
    }
}
