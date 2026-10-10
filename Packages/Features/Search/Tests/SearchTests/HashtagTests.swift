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
    func setFails(_ fails: Bool) { self.fails = fails }
    func setTop(_ top: [PostSearchHit]) { self.top = top }

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

private func hits(_ count: Int, prefix: String = "p") -> [PostSearchHit] {
    (0..<count).map { PostSearchHit(id: PostID("\(prefix)\($0)")) }
}

@MainActor
private final class Routes: Router {
    private(set) var all: [AppRoute] = []
    func route(to route: AppRoute) { all.append(route) }
}

private func hit(_ id: String) -> PostSearchHit {
    PostSearchHit(id: PostID(id))
}

@MainActor
struct HashtagViewModelTests {
    /// Both lists hold every post, text ones included: the page draws a text
    /// post as a card and tiles media into its mosaic slices itself (#629).
    @Test func bothListsHoldEveryPost() async {
        let search = TagSearch(top: [hit("a"), hit("t"), hit("b")], recent: [hit("t"), hit("a")])
        let viewModel = HashtagViewModel(tag: "#Travel", repository: search)
        await viewModel.load()

        #expect(viewModel.title == "#travel")
        #expect(viewModel.top == .posts([PostID("a"), PostID("t"), PostID("b")]))
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

    // MARK: Refresh (#798)

    /// A failed tag's Try Again (and a pull) asks again, and lands the posts.
    @Test func aFailedTagIsLoadedByItsTryAgain() async {
        let search = TagSearch(top: [hit("a")], recent: [hit("a")], fails: true)
        let viewModel = HashtagViewModel(tag: "travel", repository: search)
        await viewModel.load()
        #expect(viewModel.top == .failed(message: "Couldn\u{2019}t load #travel."))

        await search.setFails(false)
        await viewModel.refresh()

        #expect(viewModel.top == .posts([PostID("a")]))
        #expect(viewModel.recent == .posts([PostID("a")]))
    }

    /// A pull over posts keeps them on screen — never back to loading — and
    /// keeps them when it fails; when it lands, the new first page replaces them.
    @Test func aPullKeepsThePostsUntilTheNewPageReplacesThem() async {
        let search = TagSearch(top: [hit("a"), hit("b")], recent: [hit("a")])
        let viewModel = HashtagViewModel(tag: "travel", repository: search)
        await viewModel.load()
        var seen: [SearchPostSurfaceState] = []
        viewModel.onChange = { seen.append(viewModel.top) }

        await search.setFails(true)
        await viewModel.refresh()
        #expect(viewModel.top == .posts([PostID("a"), PostID("b")]))

        await search.setFails(false)
        await search.setTop([hit("c"), hit("a")])
        await viewModel.refresh()

        #expect(viewModel.top == .posts([PostID("c"), PostID("a")]))
        #expect(!seen.contains(.loading))
        #expect(!seen.contains { if case .failed = $0 { true } else { false } })
        #expect(!viewModel.isLoadingMore(.top))
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

    /// A page of text posts is a page like any other: one request, and the
    /// next waits for the viewer (it used to read on, hunting for pictures).
    @Test func topTakesAPageOfTextPostsAsItIs() async {
        let text = hits(page, prefix: "t")
        let pictures = hits(4, prefix: "m")
        let search = TagSearch(top: text + pictures)
        let viewModel = HashtagViewModel(tag: "travel", repository: search)
        await viewModel.load()
        #expect(viewModel.top == .posts(text.map(\.id)))
        #expect(viewModel.hasMore(.top))
    }

    /// The row above the list: the newest posts, at most For You's row's
    /// number — and no row while Recent has nothing to show (#629).
    @Test func theRecentRowIsTheNewestFew() async {
        let all = hits(page * 2)
        let viewModel = HashtagViewModel(tag: "travel", repository: TagSearch(recent: all))
        #expect(viewModel.recentRow == .empty(query: "#travel"), "no row while loading")
        await viewModel.load()
        await viewModel.loadMore(.recent)
        #expect(page * 2 > HashtagViewModel.rowLimit, "the premise: more posts than the row holds")
        #expect(viewModel.recentRow == .posts(Array(all.prefix(HashtagViewModel.rowLimit)).map(\.id)))

        let empty = HashtagViewModel(tag: "nothing", repository: TagSearch())
        await empty.load()
        #expect(empty.recentRow == .empty(query: "#nothing"))
    }

    /// "Top" until the backend ranks by trend (core-platform-backend#830);
    /// "Recent", never "New", which means unseen in this app.
    @Test func theSectionsAreNamedForWhatTheyAre() {
        #expect(HashtagViewModel.listTitle == "Top")
        #expect(HashtagViewModel.rowTitle == "Recent")
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
