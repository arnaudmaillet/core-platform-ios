import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Chat

// The inbox search's People section, page by page (#614).

private func person(_ number: Int) -> DirectoryPerson {
    DirectoryPerson(id: ProfileID("prof-\(number)"), handle: "user\(number)", displayName: "User \(number)")
}

private func page(_ numbers: ClosedRange<Int>, next: String?) -> DirectoryPage {
    DirectoryPage(people: numbers.map(person), nextPageToken: next)
}

/// An empty inbox: every row on screen is a directory person.
private actor EmptyInbox: ChatProviding {
    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] { [] }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        ChatMessage(id: "m", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
    }
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
}

/// Serves pages by (query, token), records every ask, and can hold a token
/// until released — to land a page after a newer query.
private actor PagedDirectory: PeopleDirectoryProviding {
    private let pages: [String: [String?: DirectoryPage]]
    private(set) var asks: [(query: String, token: String?, limit: Int32)] = []
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(_ pages: [String: [String?: DirectoryPage]]) { self.pages = pages }

    func hold(_ token: String) { held.insert(token) }
    func release(_ token: String) {
        held.remove(token)
        for waiter in waiters.removeValue(forKey: token) ?? [] { waiter.resume() }
    }
    func tokens() -> [String?] { asks.map(\.token) }

    func searchPeople(matching query: String, limit: Int32) async throws -> [DirectoryPerson] {
        try await searchPeoplePage(matching: query, limit: limit, pageToken: nil).people
    }

    func searchPeoplePage(matching query: String, limit: Int32, pageToken: String?) async throws -> DirectoryPage {
        asks.append((query, pageToken, limit))
        if let pageToken, held.contains(pageToken) {
            await withCheckedContinuation { waiters[pageToken, default: []].append($0) }
        }
        return pages[query]?[pageToken] ?? DirectoryPage(people: [], nextPageToken: nil)
    }
}

@MainActor
struct InboxPeoplePagingTests {
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

    private func makeViewModel(_ directory: PagedDirectory) async throws -> InboxSearchViewModel {
        let catalog = InboxCatalog(repository: EmptyInbox())
        catalog.reload()
        try #require(await settle { catalog.snapshot.phase == .loaded })
        return InboxSearchViewModel(
            catalog: catalog, viewer: EmptyInbox(), people: directory, debounce: .zero, pageSize: 2
        )
    }

    /// The People section's rows, in order.
    private func peopleRows(_ viewModel: InboxSearchViewModel, _ phase: InboxSearchViewModel.Phase?) -> [String] {
        guard case .content(let sections) = phase else { return [] }
        return sections.first { $0.kind == .people }?.rows.compactMap { row in
            if case .person(let id) = row { id.rawValue } else { nil }
        } ?? []
    }

    @Test func nearingTheEndAppendsTheNextPageOnceAndStopsAtTheEnd() async throws {
        let directory = PagedDirectory(["ann": [
            nil: page(1...2, next: "p2"),
            "p2": page(3...4, next: nil),
        ]])
        let viewModel = try await makeViewModel(directory)
        var phase: InboxSearchViewModel.Phase?
        var paging: [Bool] = []
        viewModel.onPhaseChange = { phase = $0 }
        viewModel.onPeoplePagingChange = { paging.append($0) }

        viewModel.queryChanged("ann")
        try #require(await settle { peopleRows(viewModel, phase) == ["prof-1", "prof-2"] })
        #expect(viewModel.hasMorePeople)

        viewModel.loadMorePeople()
        viewModel.loadMorePeople() // the same approach, reported twice
        try #require(await settle { peopleRows(viewModel, phase).count == 4 })

        #expect(peopleRows(viewModel, phase) == ["prof-1", "prof-2", "prof-3", "prof-4"])
        #expect(!viewModel.hasMorePeople)
        #expect(paging == [true, false])
        viewModel.loadMorePeople() // the end: nothing left to ask
        await idle()
        #expect(await directory.tokens() == [nil, "p2"])
        #expect(await directory.asks.allSatisfy { $0.limit == 2 })
    }

    /// Someone already shown — they slid across the boundary — is not shown
    /// twice, and a page of nobody new walks on to the next.
    @Test func aPersonAlreadyShownIsNotShownTwice() async throws {
        let directory = PagedDirectory(["ann": [
            nil: page(1...2, next: "p2"),
            "p2": page(2...2, next: "p3"),
            "p3": page(2...3, next: nil),
        ]])
        let viewModel = try await makeViewModel(directory)
        var phase: InboxSearchViewModel.Phase?
        viewModel.onPhaseChange = { phase = $0 }
        viewModel.queryChanged("ann")
        try #require(await settle { peopleRows(viewModel, phase).count == 2 })

        viewModel.loadMorePeople()
        try #require(await settle { !viewModel.hasMorePeople && peopleRows(viewModel, phase).count == 3 })
        #expect(peopleRows(viewModel, phase) == ["prof-1", "prof-2", "prof-3"])
        #expect(await directory.tokens() == [nil, "p2", "p3"])
    }

    /// A page for a superseded query never lands on the new query's rows, and
    /// the new query starts from its own first page.
    @Test func aPageForASupersededQueryNeverLands() async throws {
        let directory = PagedDirectory([
            "ann": [nil: page(1...2, next: "p2"), "p2": page(3...4, next: nil)],
            "bob": [nil: page(10...11, next: "b2")],
        ])
        await directory.hold("p2")
        let viewModel = try await makeViewModel(directory)
        var phase: InboxSearchViewModel.Phase?
        viewModel.onPhaseChange = { phase = $0 }
        viewModel.queryChanged("ann")
        try #require(await settle { peopleRows(viewModel, phase).count == 2 })

        viewModel.loadMorePeople()
        try #require(await settle { await directory.asks.count == 2 })
        viewModel.queryChanged("bob")
        try #require(await settle { peopleRows(viewModel, phase) == ["prof-10", "prof-11"] })
        await directory.release("p2")
        await idle()

        #expect(peopleRows(viewModel, phase) == ["prof-10", "prof-11"])
        #expect(viewModel.hasMorePeople) // bob's own cursor
    }

    /// Over the wire: `PeopleDirectoryRepository` follows the mock's tokens,
    /// and the pages add up to the whole answer, in order.
    @Test func theDirectoryPagesAcrossABoundary() async throws {
        let bff = MockBFF()
        MockSearchService(dataset: MockSocialDataset()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let directory = PeopleDirectoryRepository(searchClient: Search_V1_SearchServiceClient(client: client))

        let everyone = try await directory.searchPeoplePage(matching: "a", limit: 500, pageToken: nil)
        #expect(everyone.nextPageToken == nil)
        #expect(everyone.people.count > 3)
        var paged: [DirectoryPerson] = []
        var token: String?
        var pages = 0
        repeat {
            let page = try await directory.searchPeoplePage(matching: "a", limit: 3, pageToken: token)
            #expect(page.people.count <= 3)
            paged += page.people
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 50
        #expect(pages >= 2)
        #expect(paged.map(\.id) == everyone.people.map(\.id))
    }
}
