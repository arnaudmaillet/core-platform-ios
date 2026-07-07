import CoreContracts
import CoreModels
import Foundation

public enum SearchError: Error, Equatable, Sendable {
    case transport(message: String)
}

/// A profile match from search.v1, projected to just what the results list
/// renders. `id` is the profile's id, so a tap routes straight to `.profile`.
public struct ProfileSearchResult: Equatable, Sendable, Identifiable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let isVerified: Bool

    public init(id: ProfileID, handle: String, displayName: String, isVerified: Bool) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.isVerified = isVerified
    }
}

/// What the search UI consumes; implemented by `SearchRepository`, faked in
/// view-model tests.
public protocol SearchProviding: Sendable {
    /// People search. The backend token-matches (whole words, case-insensitive),
    /// so callers pass complete query terms rather than prefixes.
    func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult]
}

/// Reads people results from search.v1. Scoped to the PROFILE entity type; post
/// and hashtag search can be added as those surfaces land.
public actor SearchRepository: SearchProviding {
    private let searchClient: any Search_V1_SearchServiceClientInterface

    public init(searchClient: any Search_V1_SearchServiceClientInterface) {
        self.searchClient = searchClient
    }

    public func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var request = Search_V1_SearchRequest()
        request.query = trimmed
        request.entityTypes = [.profile]
        request.sort = .relevance
        request.pageSize = limit

        let response = await searchClient.search(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return body.hits.compactMap(Self.makeResult)
        case .failure(let error):
            throw SearchError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    /// A hit becomes a result only if it is a profile carrying an id — other
    /// entity kinds (posts, hashtags) are skipped for the people list.
    private static func makeResult(from hit: Search_V1_SearchHit) -> ProfileSearchResult? {
        guard hit.entityType == .profile, !hit.id.isEmpty else { return nil }
        return ProfileSearchResult(
            id: ProfileID(hit.id),
            handle: hit.profile.handle,
            displayName: hit.profile.displayName,
            isVerified: hit.profile.verified
        )
    }
}
