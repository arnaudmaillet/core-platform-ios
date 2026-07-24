import CoreModels

/// Matches a freshly computed set of clusters to the markers already on the map
/// so a cluster that still covers roughly the same pins keeps its marker across
/// a reconcile — instead of the old marker fading out and a near-identical one
/// fading in (the micro-flicker).
///
/// The need arises because `MapClusterEngine` recomputes clusters from scratch
/// every settle, and a cluster's "natural" identity — its lowest member id — is
/// unstable: as the viewport's Top-K pin set shifts on pan/zoom, one pin
/// entering or leaving flips the representative and, with it, the identity. Two
/// reconciles then disagree about which marker is which even though nothing
/// moved on screen. Matching by shared membership is stable through exactly
/// those churns.
///
/// Pure and unit-tested — it decides assignments from member sets alone, with
/// no `MKMapView` involved.
enum MapClusterTracker {
    /// An existing marker available to be reused, and the members it currently
    /// shows.
    struct Candidate: Equatable {
        let key: String
        let members: Set<PostID>

        init(key: String, members: Set<PostID>) {
            self.key = key
            self.members = members
        }
    }

    /// For each incoming cluster (given by its member set, in order), the key of
    /// the candidate marker it should reuse — or `nil` if it shares no member
    /// with any free candidate and is therefore genuinely new.
    ///
    /// Global-greedy: the pair with the largest overlap anywhere is bound first,
    /// then the next largest among still-free pairs, and so on. That beats
    /// per-item order — when a marker's pins split across two new clusters, the
    /// one that kept most of them wins the marker, and the other is treated as
    /// new. Ties break deterministically (incoming index, then candidate index)
    /// so the result is stable and testable.
    static func assign(incoming: [Set<PostID>], candidates: [Candidate]) -> [String?] {
        var result = [String?](repeating: nil, count: incoming.count)
        guard !candidates.isEmpty else { return result }

        var pairs: [(incoming: Int, candidate: Int, overlap: Int)] = []
        for i in incoming.indices {
            for j in candidates.indices {
                let overlap = incoming[i].intersection(candidates[j].members).count
                if overlap > 0 { pairs.append((i, j, overlap)) }
            }
        }
        pairs.sort { lhs, rhs in
            if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
            if lhs.incoming != rhs.incoming { return lhs.incoming < rhs.incoming }
            return lhs.candidate < rhs.candidate
        }

        var boundIncoming = Set<Int>()
        var boundCandidate = Set<Int>()
        for pair in pairs {
            guard !boundIncoming.contains(pair.incoming),
                  !boundCandidate.contains(pair.candidate) else { continue }
            result[pair.incoming] = candidates[pair.candidate].key
            boundIncoming.insert(pair.incoming)
            boundCandidate.insert(pair.candidate)
        }
        return result
    }
}
