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
