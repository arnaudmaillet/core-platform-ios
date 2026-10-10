import CoreModels
import CoreNavigation
import Foundation
import CoreNetworking
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

/// Holds every first-page call until the test answers it, by call number.
private final class GatedFirstPageProvider: RepointableFeedProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<Result<FeedPage, FeedError>, Never>] = [:]
    private var calls = 0
    private var returned = 0

    /// First-page calls made so far.
    var callCount: Int { lock.withLock { calls } }
    /// Answered calls handed back to the view model.
    var returnedCount: Int { lock.withLock { returned } }

    /// Answers call `number` (0-based, in call order).
    func answer(call number: Int, with result: Result<FeedPage, FeedError>) {
        let continuation = lock.withLock { waiting.removeValue(forKey: number) }
        continuation?.resume(returning: result)
    }

    func cachedFirstPage() async -> [FeedEntry]? { nil }

    /// A window change: the next first-page call is the new window's.
    func repoint(to ids: [PostID]) async {}

    func loadFirstPage() async throws -> FeedPage {
        let result = await withCheckedContinuation { continuation in
            lock.withLock {
                waiting[calls] = continuation
                calls += 1
            }
        }
        lock.withLock { returned += 1 }
        return try result.get()
    }

    func loadPage(afterToken token: String) async throws -> FeedPage {
        throw FeedError.transport(message: "unstubbed")
    }

    func loadPost(_ id: PostID) async throws -> FeedEntry {
        throw FeedError.transport(message: "unstubbed")
    }
}

/// Polls `condition` on the main actor, at most `attempts` times 10 ms apart.
@MainActor
private func eventually(attempts: Int = 500, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Whether `condition` holds on every main-actor turn of a short window — the
/// view model's continuation after an answered call runs inside it.
@MainActor
private func keepsHolding(turns: Int = 20, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<turns {
        guard condition() else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
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

        #expect(observed.last?.phase == .failed(message: "Couldn't load your timeline"))
    }

    /// ⚠️ THE NETWORK COMES BACK, THE TIMELINE LOADS (#793): a timeline that
    /// failed while offline reloads on recovery, without a tap.
    ///
    /// ⚠️ ITS OWN MONITOR: the shared one is process-wide, and flipping it
    /// reloaded every store alive in the parallel suites.
    @Test func aFailedTimelineReloadsWhenTheNetworkReturns() async {
        let provider = FakeFeedProvider()
        provider.pages[""] = .failure(.transport(message: "offline"))
        let monitor = ConnectivityMonitor(offlineGrace: 0)
        let viewModel = FeedViewModel(repository: provider)
        viewModel.connectivity = monitor
        async let failed = collectStates(viewModel) {
            if case .failed = $0.phase { return true } else { return false }
        }
        viewModel.viewDidLoad()
        _ = await failed

        provider.pages[""] = .success(FeedPage(entries: makeEntries(0..<3), nextPageToken: nil, isCold: false))
        async let recovered = collectStates(viewModel) { $0.items.count == 3 }
        monitor.report(online: false)
        monitor.report(online: true)
        let observed = await recovered

        #expect(observed.last?.items.count == 3)
    }

    /// A feed whose first load (call 0) was superseded by a window change
    /// (call 1), both still waiting, with every state it emits recorded.
    ///
    /// A `repoint`, not a pull: since #797 a pull while the first load is on
    /// its way is ignored rather than cancelling it.
    private func supersededFirstPage() async -> (FeedViewModel, GatedFirstPageProvider, () -> [FeedViewModel.RenderState]) {
        let provider = GatedFirstPageProvider()
        let viewModel = FeedViewModel(repository: provider)
        viewModel.connectivity = ConnectivityMonitor(offlineGrace: 0)
        var states: [FeedViewModel.RenderState] = []
        viewModel.onStateChange = { states.append($0) }
        viewModel.viewDidLoad()
        #expect(await eventually { provider.callCount == 1 }, "the first load never asked")
        viewModel.repoint(to: [PostID("post-new-window")])
        #expect(await eventually { provider.callCount == 2 }, "the new window never asked")
        return (viewModel, provider, { states })
    }

    /// ⚠️ A SUPERSEDED FIRST PAGE LEAVES ITS SUCCESSOR'S SLOT ALONE (#836):
    /// the first load, cancelled by a window change, ended by clearing the
    /// slot of the load that replaced it, and the feed read "nothing on its way" — the
    /// end of the list — with the new first page still in flight.
    @Test func aFirstPageSupersededByARepointLeavesTheNewLoadsSlotSet() async {
        let (viewModel, provider, _) = await supersededFirstPage()

        provider.answer(call: 0, with: .success(FeedPage(entries: makeEntries(0..<5), nextPageToken: nil, isCold: false)))
        #expect(await eventually { provider.returnedCount == 1 })
        #expect(await keepsHolding { viewModel.isLoadingNextPage }, "the superseded load cleared its successor's slot")

        provider.answer(call: 1, with: .success(FeedPage(entries: makeEntries(0..<3), nextPageToken: nil, isCold: false)))
        #expect(await eventually { !viewModel.isLoadingNextPage }, "the new load kept the slot once finished")
    }

    /// ⚠️ A SUPERSEDED FIRST PAGE WRITES NOTHING (#836): cancelling does not
    /// stop the fetch or the build, and its late answer replaced the new
    /// load's posts — after a `repoint`, the old window's in the new one.
    @Test func aSupersededFirstPagesSuccessWritesNothing() async {
        let (viewModel, provider, states) = await supersededFirstPage()
        provider.answer(call: 1, with: .success(FeedPage(entries: makeEntries(0..<3), nextPageToken: nil, isCold: false)))
        #expect(await eventually { states().last?.items.count == 3 }, "the current load never landed")
        let emitted = states().count

        provider.answer(call: 0, with: .success(FeedPage(entries: makeEntries(10..<15), nextPageToken: "stale", isCold: true)))
        #expect(await eventually { provider.returnedCount == 2 })

        #expect(await keepsHolding { states().count == emitted }, "the superseded load emitted")
        #expect(states().last?.items.map(\.id) == makeEntries(0..<3).map(\.post.id))
        #expect(states().last?.isColdRefreshing == false)
    }

    /// ⚠️ A SUPERSEDED FIRST PAGE'S FAILURE IS NOT THE FEED'S (#836): it set
    /// `.failed` over a feed whose current load was still on its way.
    @Test func aSupersededFirstPagesFailureEmitsNoFailure() async {
        let (_, provider, states) = await supersededFirstPage()

        provider.answer(call: 0, with: .failure(.transport(message: "superseded")))
        #expect(await eventually { provider.returnedCount == 1 })

        #expect(await keepsHolding {
            !states().contains { if case .failed = $0.phase { return true } else { return false } }
        }, "the superseded load's failure reached the feed")
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
