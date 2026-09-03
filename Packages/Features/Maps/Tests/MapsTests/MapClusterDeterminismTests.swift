import CoreModels
import Testing
@testable import Maps

/// **THE MAP MOVED WHEN NOTHING HAD.**
///
/// Filmed: opening a post and coming back re-laid every marker, repeatedly, on
/// a map nobody had panned or zoomed. The region IS restored across that trip —
/// nothing calls `setRegion` on any return path — so the corpus and the
/// viewport the engine is handed are the same. The answer was not.
///
/// Two independent causes, and both are shaped the same way: the engine's merge
/// is a centroid-updating single-linkage fixed point, so WHICH PAIR MERGES
/// FIRST decides the partition — and its inputs were taken from dictionaries,
/// which re-order whenever they are mutated. Every return re-queries, so every
/// return re-ordered them.
///
/// These are the assertions that would have failed before: same pins, permuted,
/// must give the same markers.
struct MapClusterDeterminismTests {
    private static let cell = 64.0

    private static func pin(_ id: String, lat: Double, lng: Double) -> MapPin {
        MapPin(
            postID: PostID(id), latitude: lat, longitude: lng,
            thumbnailURL: nil, kind: .photo
        )
    }

    /// A deterministic scatter, the same shape the overlap test uses.
    private static func scatter(_ count: Int) -> [MapPin] {
        var pins: [MapPin] = []
        for index in 0..<count {
            let latStep: Double = Double((index * 73) % 100 - 50)
            let lngStep: Double = Double((index * 137) % 100 - 50)
            let lat: Double = 48.8566 + latStep * 0.002
            let lng: Double = 2.3522 + lngStep * 0.002
            pins.append(pin("p\(index)", lat: lat, lng: lng))
        }
        return pins
    }

    /// Every marker as a value, so two runs can be compared without caring
    /// which order the engine happened to emit them in.
    private static func shape(_ items: [MapClusterEngine.Item]) -> Set<String> {
        Set(items.map { item in
            let members = item.memberIDs.map(\.rawValue).sorted().joined(separator: ",")
            return String(
                format: "%@|%.9f|%.9f", members, item.latitude, item.longitude
            )
        })
    }

    /// ⚠️ THE DEFECT, STATED. A set of pins has no order; the engine's answer
    /// must not depend on the one it happened to be handed.
    @Test func clusteringIsIndependentOfInputOrder() {
        let pins = Self.scatter(200)
        for scale in [4.0, 12.0, 40.0] {
            let reference = Self.shape(
                MapClusterEngine.cluster(pins, zoomScale: scale, cellPoints: Self.cell)
            )
            // Several fixed permutations rather than one: a single reversal can
            // pass by luck on a symmetric corpus.
            for stride in [7, 13, 31] {
                var permuted: [MapPin] = []
                var index = 0
                for _ in pins.indices {
                    permuted.append(pins[index])
                    index = (index + stride) % pins.count
                    while permuted.count < pins.count,
                          permuted.contains(where: { $0.postID == pins[index].postID }) {
                        index = (index + 1) % pins.count
                    }
                }
                #expect(
                    Self.shape(
                        MapClusterEngine.cluster(permuted, zoomScale: scale, cellPoints: Self.cell)
                    ) == reference,
                    "stride \(stride) at scale \(scale) produced different markers"
                )
            }
        }
    }

    /// ⚠️ AND THE SNAP MAY NEVER SHRINK THE CELL. `cell = cellPoints /
    /// zoomScale`, so rounding the zoom DOWN grows the cell — which is what
    /// keeps the no-overlap contract safe. Rounding up would tighten the merge
    /// threshold and could let two markers touch.
    @Test func snappingTheZoomNeverRaisesIt() {
        for z in [0.5, 1.0, 1.0001, 3.7, 12.0, 40.0, 1023.9] {
            let snapped = MapClusterEngine.snapZoom(z)
            #expect(snapped <= z + 1e-12, "snapZoom(\(z)) grew the zoom")
            #expect(snapped > 0)
            // Idempotent, so a snapped value is a fixed point of the grid.
            #expect(abs(MapClusterEngine.snapZoom(snapped) - snapped) < 1e-9)
        }
        // A zoom that does not exist yet is not a zoom.
        #expect(MapClusterEngine.snapZoom(0) == 0)
        #expect(MapClusterEngine.snapZoom(-1) == 0)
        #expect(MapClusterEngine.snapZoom(.infinity) == 0)
    }

    /// The hysteresis, as the thing it exists for: MapKit's region↔rect round
    /// trip is lossy, so the first read after the map is re-attached need not
    /// be bit-identical to the last one before it.
    @Test func anEpsilonInTheViewportDoesNotRecluster() {
        let pins = Self.scatter(120)
        for z in [3.7, 12.0, 39.9] {
            let a = MapClusterEngine.cluster(
                pins, zoomScale: MapClusterEngine.snapZoom(z), cellPoints: Self.cell
            )
            let b = MapClusterEngine.cluster(
                pins, zoomScale: MapClusterEngine.snapZoom(z.nextUp), cellPoints: Self.cell
            )
            let c = MapClusterEngine.cluster(
                pins, zoomScale: MapClusterEngine.snapZoom(z * (1 + 1e-12)), cellPoints: Self.cell
            )
            #expect(Self.shape(a) == Self.shape(b), "one ulp re-clustered at \(z)")
            #expect(Self.shape(a) == Self.shape(c), "a 1e-12 relative change re-clustered at \(z)")
        }
    }

    /// ⚠️ AND THE GUARD AGAINST FIXING IT BY FREEZING IT. A real zoom must
    /// still change the answer, or the snap has bought stability by making the
    /// map stop working.
    ///
    /// A TIGHT corpus on purpose: the scatter above is spread widely enough
    /// that four-fold and forty-fold both resolve to singles, which would make
    /// this assertion pass for the wrong reason — it did, on the first draft.
    @Test func aRealZoomStillReclusters() {
        var pins: [MapPin] = []
        for index in 0..<40 {
            let lat: Double = 48.8566 + Double(index % 8) * 0.0006
            let lng: Double = 2.3522 + Double(index / 8) * 0.0006
            pins.append(Self.pin("t\(index)", lat: lat, lng: lng))
        }
        // ⚠️ THE SCALES ARE SMALL, and that is not arbitrary. `cell =
        // cellPoints / zoomScale` is in MAP POINTS, of which the world has
        // ~2.68e8 — so 0.0006° of longitude is already ~450 of them. A merge
        // needs the cell to exceed that, which happens below zoomScale ≈ 0.14,
        // not at the double-digit scales the rest of the suite uses. Chosen by
        // measurement after a first draft asserted a difference that was not
        // there at any zoom.
        let near = MapClusterEngine.cluster(
            pins, zoomScale: MapClusterEngine.snapZoom(1.0), cellPoints: Self.cell
        )
        let far = MapClusterEngine.cluster(
            pins, zoomScale: MapClusterEngine.snapZoom(0.02), cellPoints: Self.cell
        )
        #expect(Self.shape(near) != Self.shape(far), "zooming out changed nothing")
        #expect(near.count > far.count, "a wider view should merge more")
        // And nothing is lost either way.
        #expect(Set(near.flatMap(\.memberIDs)).count == pins.count)
        #expect(Set(far.flatMap(\.memberIDs)).count == pins.count)
    }
}
