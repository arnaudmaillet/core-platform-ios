import CoreModels
import Foundation
import Testing
@testable import Notifications

// The notifications drawer, page by page (#608).

private struct PageError: Error {}

/// Serves pages by token (nil = the first), records every ask, and can fail
/// a token once.
private actor PagedProvider: NotificationsProviding {
    private var pages: [String?: NotificationsPage]
    private var failuresLeft: [String: Int] = [:]
    private(set) var asks: [(limit: Int32, token: String?)] = []

    init(_ pages: [String?: NotificationsPage]) { self.pages = pages }

    func failOnce(_ token: String) { failuresLeft[token] = 1 }
    func tokens() -> [String?] { asks.map(\.token) }

    func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
        asks.append((limit, pageToken))
        if let token = pageToken, let left = failuresLeft[token], left > 0 {
            failuresLeft[token] = left - 1
            throw PageError()
        }
        return pages[pageToken] ?? NotificationsPage(items: [], nextPageToken: nil)
    }
    func markAllRead() async throws {}
    func unreadCount() async throws -> Int { 0 }
}

/// Read rows about different posts, so nothing folds and they all sit in
/// "Earlier", most recent first by their number.
private func item(_ number: Int) -> NotificationItem {
    NotificationItem(
        id: "n\(number)", action: .reaction, senderID: ProfileID("prof-9"), senderName: "Ava",
        otherSenderCount: 0, postSubjectID: PostID("post-\(number)"), isRead: true,
        createdAt: Date(timeIntervalSince1970: 100_000 - Double(number) * 60)
    )
}

private func page(_ numbers: ClosedRange<Int>, next: String?) -> NotificationsPage {
    NotificationsPage(items: numbers.map(item), nextPageToken: next)
}

@MainActor
struct NotificationsPagingTests {
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

    /// Grace for "nothing more should happen", in looks.
    private func idle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func rowIDs(_ viewModel: NotificationsViewModel, _ phase: NotificationsViewModel.Phase?) -> [String] {
        (phase?.content ?? []).flatMap(\.rows).map(\.id)
    }

    private func loaded(_ provider: PagedProvider) async throws -> (NotificationsViewModel, () -> NotificationsViewModel.Phase?) {
        let viewModel = NotificationsViewModel(repository: provider)
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        try #require(await settle { last?.content != nil })
        return (viewModel, { last })
    }

    @Test func nearingTheEndAppendsTheNextPageOnceAndStopsAtTheEnd() async throws {
        let provider = PagedProvider([
            nil: page(0...1, next: "p2"),
            "p2": page(2...3, next: nil),
        ])
        let (viewModel, phase) = try await loaded(provider)
        #expect(rowIDs(viewModel, phase()) == ["n0", "n1"])
        #expect(viewModel.pageFooter == .loading)

        viewModel.loadNextPageIfNeeded()
        viewModel.loadNextPageIfNeeded() // the same approach, reported twice
        try #require(await settle { rowIDs(viewModel, phase()).count == 4 })

        #expect(rowIDs(viewModel, phase()) == ["n0", "n1", "n2", "n3"])
        #expect(viewModel.pageFooter == .none)
        viewModel.loadNextPageIfNeeded() // the end: nothing left to ask
        await idle()
        #expect(await provider.tokens() == [nil, "p2"])
        // Every ask carries the page size.
        #expect(await provider.asks.allSatisfy { $0.limit == 20 })
    }

    /// A row already loaded — it slid across the page boundary — is not
    /// shown twice, and a page of nothing new walks on to the next.
    @Test func aRowAlreadyLoadedIsNotShownTwice() async throws {
        let provider = PagedProvider([
            nil: page(0...1, next: "p2"),
            "p2": page(1...1, next: "p3"),
            "p3": page(1...2, next: nil),
        ])
        let (viewModel, phase) = try await loaded(provider)

        viewModel.loadNextPageIfNeeded()
        try #require(await settle { viewModel.pageFooter == .none })

        #expect(rowIDs(viewModel, phase()) == ["n0", "n1", "n2"])
        #expect(await provider.tokens() == [nil, "p2", "p3"])
    }

    /// A failed page waits for "Try Again" — nearing the end again does not
    /// hammer it — and "Try Again" asks for that same page.
    @Test func aFailedPageWaitsForTryAgain() async throws {
        let provider = PagedProvider([
            nil: page(0...1, next: "p2"),
            "p2": page(2...3, next: nil),
        ])
        await provider.failOnce("p2")
        let (viewModel, phase) = try await loaded(provider)

        viewModel.loadNextPageIfNeeded()
        try #require(await settle { viewModel.pageFooter == .retry })
        viewModel.loadNextPageIfNeeded()
        await idle()
        #expect(await provider.tokens() == [nil, "p2"])
        #expect(rowIDs(viewModel, phase()) == ["n0", "n1"])

        viewModel.retryPage()
        try #require(await settle { rowIDs(viewModel, phase()).count == 4 })
        #expect(await provider.tokens() == [nil, "p2", "p2"])
        #expect(viewModel.pageFooter == .none)
    }

    /// A refresh starts again from the first page, and the cursor follows it.
    @Test func aRefreshStartsAgainFromTheFirstPage() async throws {
        let provider = PagedProvider([
            nil: page(0...1, next: "p2"),
            "p2": page(2...3, next: nil),
        ])
        let (viewModel, phase) = try await loaded(provider)
        viewModel.loadNextPageIfNeeded()
        try #require(await settle { rowIDs(viewModel, phase()).count == 4 })

        viewModel.refresh()
        try #require(await settle { rowIDs(viewModel, phase()) == ["n0", "n1"] })
        #expect(viewModel.pageFooter == .loading)
        #expect(await provider.tokens() == [nil, "p2", nil])
    }
}
