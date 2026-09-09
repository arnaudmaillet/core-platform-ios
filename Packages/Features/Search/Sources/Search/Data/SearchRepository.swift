import CoreContracts
import CoreModels
import Foundation

public enum SearchError: Error, Equatable, Sendable {
    case transport(message: String)
}

/// How the engine should order what it returns.
///
/// ⚠️ THESE THREE ARE THE WHOLE OF IT, and the ceiling is the contract's, not
/// this screen's: `search.v1.SearchSort` has exactly `RELEVANCE`, `RECENCY` and
/// `POPULARITY`. There is no sort for comment counts, no date RANGE on
/// `SearchRequest`, and nothing that expresses a per-viewer scope — see
/// `dev/BACKEND_GAPS.md` for what was asked for and what is missing.
///
/// ⚠️ AND POPULARITY IS COARSE BY DESIGN. The generated comment says it "reads
/// the periodically-refreshed popularity signal, never a real-time count", so
/// it is not "most liked right now" and must not be labelled as if it were.
public enum SearchSortOrder: String, Equatable, Sendable, CaseIterable {
    /// What the engine thinks matches the words best. The default.
    case relevance
    /// Freshest first, at the cost of text relevance.
    case recency
    /// Coarse engagement first, at the cost of text relevance.
    case popularity
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

/// Whose results the viewer wants to see.
///
/// ⚠️ NOT ON THE WIRE, AND THAT IS THE WHOLE POINT OF THE NAME. `SearchRequest`
/// has no scope field: the only viewer-relative thing it carries is
/// `exclude_author_ids`, which the EDGE fills from the social graph so that
/// per-viewer facts stay out of the shared index. So this narrows THE RESULTS
/// ON SCREEN, not the query — a page of matches, filtered — and the sheet's
/// footer says so in those words rather than implying a narrower search.
///
/// `seen` / `unseen` are absent: nothing in this client or in the contracts
/// records which entities a viewer has looked at. See `dev/BACKEND_GAPS.md` §19.
public enum SearchScope: String, Equatable, Sendable, CaseIterable {
    case everyone
    case following
}

/// One typeahead completion from `search.v1.Suggest`.
public struct SearchSuggestion: Equatable, Sendable {
    /// What the suggestion is a completion *of*. `search.v1` can answer for
    /// posts and hashtags too; the search screen asks only for profiles today,
    /// so the other cases exist to keep an unexpected answer renderable rather
    /// than dropped.
    public enum Kind: Equatable, Sendable {
        case profile
        case post
        case hashtag
        case other
    }

    /// The completion text — a handle, a hashtag.
    public let text: String
    public let kind: Kind
    /// The resolvable id, when the entity has one. Carried but not routed on:
    /// see `SearchViewModel.didSelectSuggestion`.
    public let id: String

    public init(text: String, kind: Kind, id: String) {
        self.text = text
        self.kind = kind
        self.id = id
    }
}

/// What the search UI consumes; implemented by `SearchRepository`, faked in
/// view-model tests.
public protocol SearchProviding: Sendable {
    /// People search. The backend token-matches (whole words, case-insensitive),
    /// so callers pass complete query terms rather than prefixes.
    ///
    /// `sort` is the viewer's pick from the filter tray; it goes on the wire
    /// rather than being applied to the answer, because the engine ranks the
    /// whole index and the client only ever sees a page of it.
    func searchProfiles(
        matching query: String, sort: SearchSortOrder, limit: Int32
    ) async throws -> [ProfileSearchResult]

    /// Typeahead completions for a partial query.
    ///
    /// A *different* RPC from `searchProfiles`, not a cheaper call of the same
    /// one: `Suggest` takes a `prefix` and answers with completion text, where
    /// `Search` token-matches whole words and answers with entities. That is
    /// exactly the difference between what a half-typed query needs and what a
    /// submitted one does.
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion]
}

/// Reads people results from search.v1. Scoped to the PROFILE entity type; post
/// and hashtag search can be added as those surfaces land.
public actor SearchRepository: SearchProviding {
    private let searchClient: any Search_V1_SearchServiceClientInterface

    public init(searchClient: any Search_V1_SearchServiceClientInterface) {
        self.searchClient = searchClient
    }

    public func searchProfiles(
        matching query: String, sort: SearchSortOrder, limit: Int32
    ) async throws -> [ProfileSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var request = Search_V1_SearchRequest()
        request.query = trimmed
        request.entityTypes = [.profile]
        request.sort = Self.wireSort(sort)
        request.pageSize = limit

        let response = await searchClient.search(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return body.hits.compactMap(Self.makeResult)
        case .failure(let error):
            throw SearchError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    /// ⚠️ `.unspecified` is NOT passed for relevance. The contract documents
    /// UNSPECIFIED as *defaulting* to relevance, which makes the two
    /// interchangeable today and hostage to that default tomorrow. Naming the
    /// order the viewer picked keeps the request true to the menu.
    private static func wireSort(_ sort: SearchSortOrder) -> Search_V1_SearchSort {
        switch sort {
        case .relevance: .relevance
        case .recency: .recency
        case .popularity: .popularity
        }
    }

    public func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var request = Search_V1_SuggestRequest()
        // The sigil is stripped HERE, at the adapter, because it is a fact
        // about the index rather than about any one screen: `search.v1` stores
        // handles bare, so "@sof" is a prefix that matches nothing. The same
        // rule `PeopleDirectoryRepository` applies to its own query.
        request.prefix = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        request.entityTypes = [.profile]
        request.limit = limit

        let response = await searchClient.suggest(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return body.suggestions.compactMap(Self.makeSuggestion)
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

    /// A suggestion with no text is nothing to render and nothing to search
    /// for, whatever its entity type.
    private static func makeSuggestion(from suggestion: Search_V1_Suggestion) -> SearchSuggestion? {
        let text = suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let kind: SearchSuggestion.Kind = switch suggestion.entityType {
        case .profile: .profile
        case .post: .post
        case .hashtag: .hashtag
        case .unspecified, .UNRECOGNIZED: .other
        }
        return SearchSuggestion(text: text, kind: kind, id: suggestion.id)
    }
}
