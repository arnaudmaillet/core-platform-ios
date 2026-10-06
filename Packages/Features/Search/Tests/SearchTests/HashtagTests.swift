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
    private(set) var queries: [String] = []

    init(top: [PostSearchHit] = [], recent: [PostSearchHit] = [], count: Int? = nil, fails: Bool = false) {
        self.top = top
        self.recent = recent
        self.count = count
        self.fails = fails
    }

    func searchProfiles(matching query: String, sort: SearchSortOrder, limit: Int32) async throws -> [ProfileSearchResult] { [] }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
    func searchPosts(matching query: String, sort: SearchSortOrder, limit: Int32) async throws -> [PostSearchHit] {
        queries.append(query)
        if fails { throw SearchError.transport(message: "offline") }
        return sort == .popularity ? top : recent
    }
    func hashtagPostCount(_ tag: String) async throws -> Int? { count }
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

        let full = (0..<Int(HashtagViewModel.pageSize)).map { hit("p\($0)") }
        let big = HashtagViewModel(tag: "travel", repository: TagSearch(recent: full, count: 1_500))
        await big.load()
        #expect(big.countText == "1.5K posts")

        let one = HashtagViewModel(tag: "travel", repository: TagSearch(recent: [hit("a")]))
        await one.load()
        #expect(one.countText == "1 post")
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
