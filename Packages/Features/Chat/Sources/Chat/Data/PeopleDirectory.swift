import CoreContracts
import CoreModels
import Foundation

/// Someone the viewer can start a conversation with, as the compose picker
/// renders them.
///
/// Deliberately NOT `SuggestedAccount`: a directory hit carries no reason and
/// no follow state — it is a name the viewer typed towards, not a
/// recommendation — and giving it those fields would mean inventing values for
/// them at every call site.
public struct DirectoryPerson: Equatable, Sendable, Identifiable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let isVerified: Bool

    public init(id: ProfileID, handle: String, displayName: String, isVerified: Bool = false) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.isVerified = isVerified
    }
}

/// One page of directory people, and where the next one starts (#614).
public struct DirectoryPage: Equatable, Sendable {
    public let people: [DirectoryPerson]
    /// Nil when there is no next page.
    public let nextPageToken: String?

    public init(people: [DirectoryPerson], nextPageToken: String?) {
        self.people = people
        self.nextPageToken = nextPageToken
    }
}

public enum PeopleDirectoryError: Error, Equatable, Sendable {
    case transport(message: String)
}

/// The people-lookup the compose picker searches against.
///
/// Declared here rather than reused from the Search feature because features
/// never import each other: Chat states the shape it needs, and the
/// composition root points it at whatever answers it. Same arrangement as
/// `SuggestionsProviding`.
public protocol PeopleDirectoryProviding: Sendable {
    /// People matching `query`. The backend token-matches, so callers pass
    /// whole terms rather than prefixes.
    func searchPeople(matching query: String, limit: Int32) async throws -> [DirectoryPerson]
    /// One page of `searchPeople`: `pageToken` nil for the first, then the
    /// `nextPageToken` of the page before (#614).
    func searchPeoplePage(matching query: String, limit: Int32, pageToken: String?) async throws -> DirectoryPage
}

extension PeopleDirectoryProviding {
    /// One page holding `searchPeople`'s answer, and no next one — for a
    /// directory that does not page.
    public func searchPeoplePage(matching query: String, limit: Int32, pageToken: String?) async throws -> DirectoryPage {
        guard pageToken == nil else { return DirectoryPage(people: [], nextPageToken: nil) }
        return DirectoryPage(people: try await searchPeople(matching: query, limit: limit), nextPageToken: nil)
    }
}

/// Reads people from `search.v1`, scoped to the PROFILE entity type.
///
/// Rows render as monograms: `Search_V1_ProfileHit` carries `avatar_key` — a
/// storage key, not a URL — and nothing in the app resolves keys to URLs today
/// (the mock doesn't even populate the field). Turning hits into avatars would
/// mean a `GetProfileById` per result purely for an image, which is a per-
/// keystroke fan-out; the monogram is what the chat surfaces show anyway.
public actor PeopleDirectoryRepository: PeopleDirectoryProviding {
    private let searchClient: any Search_V1_SearchServiceClientInterface

    public init(searchClient: any Search_V1_SearchServiceClientInterface) {
        self.searchClient = searchClient
    }

    public func searchPeople(matching query: String, limit: Int32) async throws -> [DirectoryPerson] {
        try await searchPeoplePage(matching: query, limit: limit, pageToken: nil).people
    }

    public func searchPeoplePage(matching query: String, limit: Int32, pageToken: String?) async throws -> DirectoryPage {
        // The sigil is stripped HERE, at the adapter, because it is a fact about
        // the index rather than about any one screen: `search.v1` stores handles
        // bare, so "@sofia" is a term that matches nothing. Doing it here also
        // keeps it off every caller — the inbox's search and the compose picker
        // both get it, and neither has to remember to.
        let trimmed = TextMatch.normalize(query)
        guard !trimmed.isEmpty else { return DirectoryPage(people: [], nextPageToken: nil) }

        var request = Search_V1_SearchRequest()
        request.query = trimmed
        request.entityTypes = [.profile]
        request.sort = .relevance
        request.pageSize = limit
        request.pageToken = pageToken ?? ""

        let response = await searchClient.search(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return DirectoryPage(
                people: body.hits.compactMap(Self.makePerson),
                nextPageToken: body.nextPageToken.isEmpty ? nil : body.nextPageToken
            )
        case .failure(let error):
            throw PeopleDirectoryError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    /// A hit becomes a person only if it is a profile carrying an id — the
    /// same query can return posts and hashtags once those are indexed.
    private static func makePerson(from hit: Search_V1_SearchHit) -> DirectoryPerson? {
        guard hit.entityType == .profile, !hit.id.isEmpty else { return nil }
        return DirectoryPerson(
            id: ProfileID(hit.id),
            handle: hit.profile.handle,
            displayName: hit.profile.displayName,
            isVerified: hit.profile.verified
        )
    }
}
