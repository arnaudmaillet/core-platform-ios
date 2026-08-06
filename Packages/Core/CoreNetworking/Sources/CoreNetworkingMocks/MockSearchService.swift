import Connect
import CoreContracts
import Foundation

/// Fake of search.v1.SearchService over the shared dataset. People search is a
/// case-insensitive substring match on handle and display name (friendlier than
/// the real backend's token match, so offline typeahead feels responsive); post
/// search matches captions the same way — the profile gallery's "Tagged"
/// category rides it with `@handle` queries against the seeded mentions.
///
/// `Suggest` is prefix-matched instead — see the method. `MultiSearch` is still
/// unrouted: nothing calls it, and a fake for an RPC with no caller would be a
/// guess about a shape no screen has had to agree with yet.
public final class MockSearchService: @unchecked Sendable {
    private let dataset: MockSocialDataset

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/search.v1.SearchService/Search") { [self] (request: Search_V1_SearchRequest) in
            search(request)
        }
        bff.register(path: "/search.v1.SearchService/Suggest") { [self] (request: Search_V1_SuggestRequest) in
            suggest(request)
        }
    }

    /// Typeahead completions.
    ///
    /// **Prefix, not substring — unlike `Search` above.** The contract's field
    /// is literally `prefix`, and the difference is what makes the two RPCs
    /// worth having separately: half a word should complete to the handles it
    /// starts, not to every handle that contains it. Display names are matched
    /// per WORD, so "whit" finds "Sam Whitfield" without "itfield" doing so.
    ///
    /// Completions are handles rather than display names: the handle is what
    /// the index stores and what a viewer finishing a search means to type.
    private func suggest(_ request: Search_V1_SuggestRequest) -> Result<Search_V1_SuggestResponse, ConnectError> {
        var response = Search_V1_SuggestResponse()

        let prefix = request.prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.isEmpty else { return .success(response) }

        let wantsProfiles = request.entityTypes.isEmpty || request.entityTypes.contains(.profile)
        guard wantsProfiles else { return .success(response) }

        let matches = dataset.authors.filter { author in
            author.handle.lowercased().hasPrefix(prefix)
                || author.displayName.lowercased()
                    .split(separator: " ")
                    .contains { $0.hasPrefix(prefix) }
        }
        let limit = request.limit > 0 ? Int(request.limit) : matches.count
        response.suggestions = matches.prefix(limit).map { author in
            var suggestion = Search_V1_Suggestion()
            suggestion.entityType = .profile
            suggestion.text = author.handle
            suggestion.id = author.profileID
            return suggestion
        }
        return .success(response)
    }

    private func search(_ request: Search_V1_SearchRequest) -> Result<Search_V1_SearchResponse, ConnectError> {
        var response = Search_V1_SearchResponse()

        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return .success(response) }

        let wantsProfiles = request.entityTypes.isEmpty || request.entityTypes.contains(.profile)
        let wantsPosts = request.entityTypes.isEmpty || request.entityTypes.contains(.post)

        if wantsProfiles {
            let matches = dataset.authors.filter {
                $0.handle.lowercased().contains(query) || $0.displayName.lowercased().contains(query)
            }
            response.hits += matches.map { author in
                var hit = Search_V1_SearchHit()
                hit.entityType = .profile
                hit.id = author.profileID
                var profile = Search_V1_ProfileHit()
                profile.handle = author.handle
                profile.displayName = author.displayName
                hit.profile = profile
                return hit
            }
        }

        if wantsPosts {
            let matches = dataset.posts.filter { $0.caption.lowercased().contains(query) }
            response.hits += matches.map { record in
                var hit = Search_V1_SearchHit()
                hit.entityType = .post
                hit.id = record.postID
                var post = Search_V1_PostHit()
                post.authorID = record.authorProfileID
                post.authorHandle = dataset.author(for: record.authorProfileID)?.handle ?? ""
                hit.post = post
                return hit
            }
        }

        response.estimatedTotal = Int64(response.hits.count)
        return .success(response)
    }
}
