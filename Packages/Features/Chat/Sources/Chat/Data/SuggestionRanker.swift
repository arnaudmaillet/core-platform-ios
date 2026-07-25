import CoreModels

/// Ranks account suggestions from the viewer's follow graph.
///
/// **This is a client-side stand-in, and deliberately a pure one.** There is no
/// recommendation service: `social_graph.v1` exposes follow edges and nothing
/// else (no `ListSuggestions`, no scores, no embeddings). Rather than scatter
/// heuristics through a repository, the entire notion of "who should we
/// suggest" is this one function over sets — so it is exhaustively testable,
/// and so replacing it with a server ranking is deleting a file rather than
/// unpicking a data layer.
///
/// Two tiers, in order:
/// 1. **Follows you, unfollowed back.** The strongest signal the graph has —
///    someone already chose the viewer.
/// 2. **Friends of friends**, ranked by how many of the viewer's own follows
///    also follow them.
///
/// Ties break on profile id so the list is stable across reloads: a suggestion
/// that reshuffles under the finger is worse than a mediocre suggestion.
enum SuggestionRanker {
    struct Input {
        var viewer: ProfileID
        /// Who follows the viewer.
        var followers: Set<ProfileID>
        /// Who the viewer follows.
        var following: Set<ProfileID>
        /// For each account the viewer follows, who *that* account follows.
        var followingOfFollowing: [ProfileID: Set<ProfileID>] = [:]
        /// Suggestions the viewer dismissed this session.
        var dismissed: Set<ProfileID> = []
    }

    struct Candidate: Equatable {
        let id: ProfileID
        /// This account follows the viewer, who doesn't follow back.
        let followsViewer: Bool
        /// Accounts the viewer follows who also follow this candidate, in
        /// stable order — the "Followed by Ava + 2" line is built from these.
        let connectors: [ProfileID]

        /// Tier first, then connector count. The tier gap is wide enough that
        /// no number of connectors can outrank a direct follower.
        var score: Int { (followsViewer ? 1_000_000 : 0) + connectors.count }
    }

    static func rank(_ input: Input, limit: Int = 20) -> [Candidate] {
        var connectorsByCandidate: [ProfileID: [ProfileID]] = [:]
        // Deterministic connector order: the viewer's follows, sorted.
        for connector in input.following.sorted(by: { $0.rawValue < $1.rawValue }) {
            for candidate in input.followingOfFollowing[connector] ?? [] {
                connectorsByCandidate[candidate, default: []].append(connector)
            }
        }

        let pool = Set(connectorsByCandidate.keys)
            .union(input.followers)
            .subtracting(input.following)
            .subtracting(input.dismissed)
            .subtracting([input.viewer])

        return pool
            .map { id in
                Candidate(
                    id: id,
                    followsViewer: input.followers.contains(id),
                    connectors: connectorsByCandidate[id] ?? []
                )
            }
            .sorted {
                $0.score != $1.score ? $0.score > $1.score : $0.id.rawValue < $1.id.rawValue
            }
            .prefix(limit)
            .map(\.self)
    }
}
