import Connect
import CoreContracts
import Foundation

/// Fake of search.v1.SearchService over the shared dataset. People search only:
/// case-insensitive substring match on handle and display name (friendlier than
/// the real backend's token match, so offline typeahead feels responsive).
public final class MockSearchService: @unchecked Sendable {
    private let dataset: MockSocialDataset

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/search.v1.SearchService/Search") { [self] (request: Search_V1_SearchRequest) in
            search(request)
        }
    }

    private func search(_ request: Search_V1_SearchRequest) -> Result<Search_V1_SearchResponse, ConnectError> {
        var response = Search_V1_SearchResponse()

        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return .success(response) }

        // Only profile search is mocked; an explicit non-profile filter yields nothing.
        let wantsProfiles = request.entityTypes.isEmpty || request.entityTypes.contains(.profile)
        guard wantsProfiles else { return .success(response) }

        let matches = dataset.authors.filter {
            $0.handle.lowercased().contains(query) || $0.displayName.lowercased().contains(query)
        }
        response.hits = matches.map { author in
            var hit = Search_V1_SearchHit()
            hit.entityType = .profile
            hit.id = author.profileID
            var profile = Search_V1_ProfileHit()
            profile.handle = author.handle
            profile.displayName = author.displayName
            hit.profile = profile
            return hit
        }
        response.estimatedTotal = Int64(response.hits.count)
        return .success(response)
    }
}
