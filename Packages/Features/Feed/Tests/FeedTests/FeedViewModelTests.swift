import CoreModels
import CoreNavigation
import Foundation
import Testing
@testable import Feed

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private final class FakeFeedProvider: FeedProviding, @unchecked Sendable {
    private let lock = NSLock()
    var cached: [FeedEntry]?
    var pages: [String: Result<FeedPage, FeedError>] = [:]
    private(set) var firstPageLoads = 0

    func cachedFirstPage() async -> [FeedEntry]? {
        lock.withLock { cached }
    }

    func loadFirstPage() async throws -> FeedPage {
        try lock.withLock {
            firstPageLoads += 1
            return try (pages[""] ?? .failure(.transport(message: "unstubbed"))).get()
        }
    }

    func loadPage(afterToken token: String) async throws -> FeedPage {
        try lock.withLock {
            try (pages[token] ?? .failure(.transport(message: "unstubbed"))).get()
        }
    }

    var post: Result<FeedEntry, FeedError> = .failure(.transport(message: "unstubbed"))
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        try lock.withLock { try post.get() }
    }
}

private func makeEntries(_ range: Range<Int>) -> [FeedEntry] {
    range.map { index in
        FeedEntry(
            post: Post(
                id: PostID(String(format: "post-%03d", index)),
                authorID: ProfileID("prof-1"),
                caption: "Caption \(index)",
                attachments: [],
                publishedAt: Date(timeIntervalSince1970: TimeInterval(1000 - index))
            ),
            author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava", avatarURL: nil)
        )
    }
}

@MainActor
struct FeedViewModelTests {
    private func collectStates(_ viewModel: FeedViewModel, until predicate: @escaping (FeedViewModel.RenderState) -> Bool) async -> [FeedViewModel.RenderState] {
        await withCheckedContinuation { continuation in
            var states: [FeedViewModel.RenderState] = []
            viewModel.onStateChange = { state in
                states.append(state)
                if predicate(state) {
                    viewModel.onStateChange = nil
                    continuation.resume(returning: states)
                }
            }
        }
    }

    @Test func tappingAuthorRoutesToProfile() {
        let router = SpyRouter()
        let viewModel = FeedViewModel(repository: FakeFeedProvider(), router: router)
        // No entries loaded yet → the route carries no identity stub.
        viewModel.didTapAuthor(ProfileID("prof-99"))
        #expect(router.routes == [.profile(ProfileID("prof-99"), stub: nil)])
    }

    @Test func tappingCommentsRoutesToComments() {
        let router = SpyRouter()
        let viewModel = FeedViewModel(repository: FakeFeedProvider(), router: router)
        viewModel.didTapComments(PostID("post-7"))
        #expect(router.routes == [.comments(PostID("post-7"))])
    }

    @Test func rendersCachedSnapshotBeforeNetworkTruth() async {
        let provider = FakeFeedProvider()
        provider.cached = makeEntries(0..<3)
        provider.pages[""] = .success(FeedPage(entries: makeEntries(0..<5), nextPageToken: nil, isCold: false))
        let viewModel = FeedViewModel(repository: provider)

        async let states = collectStates(viewModel) { $0.items.count == 5 }
        viewModel.viewDidLoad()
        let observed = await states

        // First a 3-item render from the snapshot, then the 5-item network truth.
        #expect(observed.first?.items.count == 3)
        #expect(observed.last?.items.count == 5)
        #expect(observed.last?.phase == .content)
    }

    @Test func coldFlagSurfacesAndClearsOnRefresh() async {
        let provider = FakeFeedProvider()
        provider.pages[""] = .success(FeedPage(entries: makeEntries(0..<2), nextPageToken: nil, isCold: true))
        let viewModel = FeedViewModel(repository: provider)

        async let first = collectStates(viewModel) { $0.phase == .content }
        viewModel.viewDidLoad()
        #expect(await first.last?.isColdRefreshing == true)

        provider.pages[""] = .success(FeedPage(entries: makeEntries(0..<2), nextPageToken: nil, isCold: false))
        async let second = collectStates(viewModel) { !$0.isColdRefreshing }
        viewModel.refresh()
        #expect(await second.last?.isColdRefreshing == false)
    }

    @Test func scrollingNearEndLoadsNextPageAndDeduplicates() async {
        let provider = FakeFeedProvider()
        provider.pages[""] = .success(FeedPage(entries: makeEntries(0..<10), nextPageToken: "10", isCold: false))
        // Overlapping page: items 8..<10 repeat and must not duplicate.
        provider.pages["10"] = .success(FeedPage(entries: makeEntries(8..<20), nextPageToken: nil, isCold: false))
        let viewModel = FeedViewModel(repository: provider)

        async let initial = collectStates(viewModel) { $0.items.count == 10 }
        viewModel.viewDidLoad()
        _ = await initial

        async let paged = collectStates(viewModel) { $0.items.count > 10 }
        viewModel.willDisplayItem(at: 7) // within the 5-from-end trigger window
        let observed = await paged

        let ids = observed.last!.items.map(\.id)
        #expect(ids.count == 20)
        #expect(Set(ids).count == 20)
    }

    @Test func networkFailureWithEmptyFeedShowsRetryMessage() async {
        let provider = FakeFeedProvider()
        provider.pages[""] = .failure(.transport(message: "offline"))
        let viewModel = FeedViewModel(repository: provider)

        async let states = collectStates(viewModel) {
            if case .failed = $0.phase { return true } else { return false }
        }
        viewModel.viewDidLoad()
        let observed = await states

        #expect(observed.last?.phase == .failed(message: "Couldn't load your timeline. Pull to retry."))
    }

    @Test func networkFailureKeepsCachedContentVisible() async {
        let provider = FakeFeedProvider()
        provider.cached = makeEntries(0..<4)
        provider.pages[""] = .failure(.transport(message: "offline"))
        let viewModel = FeedViewModel(repository: provider)

        async let states = collectStates(viewModel) { $0.items.count == 4 }
        viewModel.viewDidLoad()
        let observed = await states

        // Snapshot stays on screen; no failure phase while content exists.
        #expect(observed.last?.phase == .content)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(observed.allSatisfy { state in
            if case .failed = state.phase { return false } else { return true }
        })
    }
}
