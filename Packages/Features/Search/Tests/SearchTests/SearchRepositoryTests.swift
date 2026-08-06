import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Search

/// Drives the read path — repository → generated client → real ProtocolClient
/// → MockBFF — with production wire bytes, in-process.
struct SearchRepositoryTests {
    private func makeRepository(
        handler: @escaping @Sendable (Search_V1_SearchRequest) -> Search_V1_SearchResponse
    ) -> SearchRepository {
        let bff = MockBFF()
        bff.register(path: "/search.v1.SearchService/Search") { (request: Search_V1_SearchRequest) in
            .success(handler(request))
        }
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return SearchRepository(searchClient: Search_V1_SearchServiceClient(client: client))
    }

    private func profileHit(id: String, handle: String, name: String, verified: Bool = false) -> Search_V1_SearchHit {
        var hit = Search_V1_SearchHit()
        hit.entityType = .profile
        hit.id = id
        var profile = Search_V1_ProfileHit()
        profile.handle = handle
        profile.displayName = name
        profile.verified = verified
        hit.profile = profile
        return hit
    }

    @Test func mapsProfileHitsToResults() async throws {
        let repository = makeRepository { _ in
            var response = Search_V1_SearchResponse()
            response.hits = [
                profileHit(id: "prof-1", handle: "alice", name: "Alice Anderson", verified: true),
                profileHit(id: "prof-2", handle: "bob", name: "Bob Barker")
            ]
            return response
        }

        let results = try await repository.searchProfiles(matching: "a", limit: 25)

        #expect(results.count == 2)
        #expect(results.first?.id == ProfileID("prof-1"))
        #expect(results.first?.handle == "alice")
        #expect(results.first?.isVerified == true)
    }

    @Test func passesTheTrimmedQueryAndProfileFilterToTheService() async throws {
        let received = QueryBox()
        let repository = makeRepository { request in
            received.set(query: request.query, types: request.entityTypes)
            return Search_V1_SearchResponse()
        }

        _ = try await repository.searchProfiles(matching: "  alice  ", limit: 25)

        #expect(received.query == "alice")
        #expect(received.types == [.profile])
    }

    @Test func skipsNonProfileAndIdlessHits() async throws {
        let repository = makeRepository { _ in
            var postHit = Search_V1_SearchHit()
            postHit.entityType = .post
            postHit.id = "post-1"
            var response = Search_V1_SearchResponse()
            response.hits = [postHit, profileHit(id: "prof-9", handle: "carol", name: "Carol")]
            return response
        }

        let results = try await repository.searchProfiles(matching: "c", limit: 25)

        #expect(results.map(\.id) == [ProfileID("prof-9")])
    }

    @Test func emptyQueryShortCircuitsWithoutCallingTheService() async throws {
        let called = QueryBox()
        let repository = makeRepository { request in
            called.set(query: request.query, types: request.entityTypes)
            return Search_V1_SearchResponse()
        }

        let results = try await repository.searchProfiles(matching: "   ", limit: 25)

        #expect(results.isEmpty)
        #expect(called.query == nil) // never hit the wire
    }

    // MARK: - Suggest

    private func makeSuggestRepository(
        handler: @escaping @Sendable (Search_V1_SuggestRequest) -> Search_V1_SuggestResponse
    ) -> SearchRepository {
        let bff = MockBFF()
        bff.register(path: "/search.v1.SearchService/Suggest") { (request: Search_V1_SuggestRequest) in
            .success(handler(request))
        }
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return SearchRepository(searchClient: Search_V1_SearchServiceClient(client: client))
    }

    private func completion(
        _ text: String, id: String = "", type: Search_V1_SearchEntityType = .profile
    ) -> Search_V1_Suggestion {
        var suggestion = Search_V1_Suggestion()
        suggestion.entityType = type
        suggestion.text = text
        suggestion.id = id
        return suggestion
    }

    @Test func mapsCompletionsAndTheirEntityKinds() async throws {
        let repository = makeSuggestRepository { _ in
            var response = Search_V1_SuggestResponse()
            response.suggestions = [
                completion("sofia", id: "prof-1"),
                completion("swift", type: .hashtag)
            ]
            return response
        }

        let suggestions = try await repository.suggestions(forPrefix: "s", limit: 8)

        #expect(suggestions.map(\.text) == ["sofia", "swift"])
        #expect(suggestions.map(\.kind) == [.profile, .hashtag])
        #expect(suggestions.first?.id == "prof-1")
    }

    /// `search.v1` stores handles bare, so "@sof" is a prefix that matches
    /// nothing. The sigil is stripped at the adapter, because it is a fact
    /// about the index rather than about any one screen.
    @Test func stripsTheSigilBeforeItReachesTheIndex() async throws {
        let received = PrefixBox()
        let repository = makeSuggestRepository { request in
            received.set(prefix: request.prefix, limit: request.limit)
            return Search_V1_SuggestResponse()
        }

        _ = try await repository.suggestions(forPrefix: "  @sof  ", limit: 8)

        #expect(received.prefix == "sof")
        #expect(received.limit == 8)
    }

    /// A completion with no text is nothing to render and nothing to search
    /// for, whatever its entity type says.
    @Test func dropsTextlessCompletions() async throws {
        let repository = makeSuggestRepository { _ in
            var response = Search_V1_SuggestResponse()
            response.suggestions = [completion("   "), completion("sofia")]
            return response
        }

        #expect(try await repository.suggestions(forPrefix: "s", limit: 8).map(\.text) == ["sofia"])
    }

    @Test func anEmptyPrefixShortCircuitsWithoutCallingTheService() async throws {
        let received = PrefixBox()
        let repository = makeSuggestRepository { request in
            received.set(prefix: request.prefix, limit: request.limit)
            return Search_V1_SuggestResponse()
        }

        #expect(try await repository.suggestions(forPrefix: " ", limit: 8).isEmpty)
        #expect(received.prefix == nil) // never hit the wire
    }
}

private final class PrefixBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _prefix: String?
    private var _limit: Int32 = 0
    var prefix: String? { lock.withLock { _prefix } }
    var limit: Int32 { lock.withLock { _limit } }
    func set(prefix: String, limit: Int32) {
        lock.withLock { _prefix = prefix; _limit = limit }
    }
}

private final class QueryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _query: String?
    private var _types: [Search_V1_SearchEntityType] = []
    var query: String? { lock.withLock { _query } }
    var types: [Search_V1_SearchEntityType] { lock.withLock { _types } }
    func set(query: String, types: [Search_V1_SearchEntityType]) {
        lock.withLock { _query = query; _types = types }
    }
}
