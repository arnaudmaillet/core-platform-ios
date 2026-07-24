import CoreModels
import Testing
@testable import Maps

/// `MapClusterTracker` — matches recomputed clusters to the markers already on
/// the map by shared membership, so a group that still covers roughly the same
/// pins keeps its marker across a reconcile (no fade-out/fade-in flicker).
struct MapClusterTrackerTests {
    private static func ids(_ names: [String]) -> Set<PostID> { Set(names.map { PostID($0) }) }
    private static func candidate(_ key: String, _ names: [String]) -> MapClusterTracker.Candidate {
        .init(key: key, members: ids(names))
    }

    @Test func aStableClusterKeepsItsMarkerWhenTheRepresentativeChurns() {
        // The marker showed {a,b,c}; the recomputed cluster dropped `a` and
        // gained `d` — a different lowest id, but the same group.
        let matches = MapClusterTracker.assign(
            incoming: [Self.ids(["b", "c", "d"])],
            candidates: [Self.candidate("m1", ["a", "b", "c"])]
        )
        #expect(matches == ["m1"])
    }

    @Test func aGenuinelyNewClusterMatchesNothing() {
        let matches = MapClusterTracker.assign(
            incoming: [Self.ids(["x", "y"])],
            candidates: [Self.candidate("m1", ["a", "b"])]
        )
        #expect(matches == [nil])
    }

    @Test func noCandidatesMeansEverythingIsNew() {
        let matches = MapClusterTracker.assign(
            incoming: [Self.ids(["a"]), Self.ids(["b", "c"])],
            candidates: []
        )
        #expect(matches == [nil, nil])
    }

    @Test func eachMarkerIsClaimedAtMostOnce() {
        // One marker {a,b,c,d}; the group split into two. The half that kept
        // more members wins the marker; the other is new.
        let matches = MapClusterTracker.assign(
            incoming: [Self.ids(["a", "b", "c"]), Self.ids(["d"])],
            candidates: [Self.candidate("m1", ["a", "b", "c", "d"])]
        )
        #expect(matches == ["m1", nil])
    }

    @Test func theLargerOverlapWinsRegardlessOfOrder() {
        // Incoming[0] shares 1 with m1; incoming[1] shares 3 with m1. The
        // stronger match must win the marker even though it comes second.
        let matches = MapClusterTracker.assign(
            incoming: [Self.ids(["a", "x", "y"]), Self.ids(["a", "b", "c"])],
            candidates: [Self.candidate("m1", ["a", "b", "c"])]
        )
        #expect(matches == [nil, "m1"])
    }

    @Test func twoMergingClustersEachTrackTheirOwnMarker() {
        // Two markers merge into one group at a lower zoom: the merged cluster
        // can only reuse one marker (the greater overlap); the other departs.
        let matches = MapClusterTracker.assign(
            incoming: [Self.ids(["a", "b", "c", "d", "e"])],
            candidates: [
                Self.candidate("m1", ["a", "b", "c"]),
                Self.candidate("m2", ["d", "e"])
            ]
        )
        #expect(matches == ["m1"]) // m1 shares 3, m2 shares 2 → m1 wins; m2 unclaimed
    }

    @Test func disjointClustersEachKeepTheirMarker() {
        let matches = MapClusterTracker.assign(
            incoming: [Self.ids(["a", "b"]), Self.ids(["c", "d"])],
            candidates: [
                Self.candidate("m1", ["a", "b"]),
                Self.candidate("m2", ["c", "d"])
            ]
        )
        #expect(matches == ["m1", "m2"])
    }

    @Test func matchingIsDeterministicOnTiedOverlaps() {
        // Both candidates share exactly one member with the incoming cluster;
        // the tie must resolve the same way every run (lowest candidate index).
        let incoming = [Self.ids(["a", "c"])]
        let candidates = [Self.candidate("m1", ["a", "z"]), Self.candidate("m2", ["c", "z"])]
        let first = MapClusterTracker.assign(incoming: incoming, candidates: candidates)
        let second = MapClusterTracker.assign(incoming: incoming, candidates: candidates)
        #expect(first == second)
        #expect(first == ["m1"])
    }
}
