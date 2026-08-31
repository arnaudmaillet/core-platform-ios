import CoreModels
import Foundation
import MapKit

/// Client-side clustering, replacing `MKMapView`'s built-in pass.
///
/// MapKit's own clustering degrades irreparably across extended pan+zoom: once
/// its annotation views are realized it runs only an incremental pass that
/// skips them, so on any zoom-out after the first, most pins fail to group —
/// and this happens even for an annotation set we never mutate (measured: an
/// immutable 80-pin set stacks 57 pins after ~10 navigation actions). No
/// annotation-management strategy escapes it, because the defect is in the
/// engine, not in how we feed it.
///
/// Computing the layout ourselves sidesteps the engine entirely: the map view
/// is handed exactly the markers to draw (singles plus one representative per
/// group), each a plain annotation with no `clusteringIdentifier`, so MapKit
/// places every one at its coordinate and never runs the pass that breaks.
///
/// Kept free of `MKMapView` so it is pure and unit-testable — it takes a
/// projection scale in, not a live map.
enum MapClusterEngine {
    /// One thing to draw: a lone pin (`memberIDs.count == 1`) or a group.
    struct Item: Equatable {
        /// The pin whose face the marker shows — the group's most-liked
        /// member, of whatever kind (see `representative(of:)`), or the lone
        /// pin itself.
        let representative: MapPin
        /// Every post folded into this marker, representative included — the
        /// REPRESENTATIVE FIRST, then the rest ascending by id. A cluster tap
        /// opens all of them, in this order.
        ///
        /// The order is load-bearing at exactly one place and it is the one the
        /// viewer sees: the feed opens on `memberIDs[0]`
        /// (`FixedPostsFeedProvider` preserves the tapped order), so leading
        /// with the representative is what makes the page you land on the post
        /// whose face you just tapped.
        ///
        /// Written as an explicit rotation rather than relying on the current
        /// rule happening to pick `ordered[0]`: it is the invariant "you land on
        /// what you tapped" that matters, and a future face rule must not be
        /// able to break it silently. A media-preferring rule DID break it
        /// once — tapping a photograph opened a text post.
        let memberIDs: [PostID]
        /// Where the marker sits: the pin's own coordinate for a single, the
        /// members' centroid for a group.
        let latitude: Double
        let longitude: Double
        /// The one place EVERY member belongs to, or `nil` for a mixed or
        /// untagged group. Set on singles too (it is the pin's own tag), but
        /// behaviour keys on `isSemanticCluster`: a lone pin is Case A
        /// whatever it is tagged with.
        let place: MapPlace?
        /// Whether this item was produced BY the semantic pre-pass — i.e. it
        /// is the active band's marker for its place. Only these wear the
        /// hierarchy ring colors: a LOCAL-band proximity cluster that happens
        /// to share a leaf place keeps its gallery tap (`isSemanticCluster`)
        /// but dresses neutral, because below the city band everything on
        /// screen is ordinary local content.
        var isHierarchyMarker = false

        var isCluster: Bool { memberIDs.count > 1 }

        /// A multi-post group whose members all share one place — the ONLY
        /// marker whose tap opens the place gallery behind the feed (Case B).
        var isSemanticCluster: Bool { isCluster && place != nil }

        /// The representative's id. Note this is NOT a stable marker identity: a
        /// cluster's representative churns as the Top-K set shifts, which is
        /// exactly why the map layer tracks clusters by membership overlap
        /// (`MapClusterTracker`) rather than keying off this.
        var key: PostID { representative.postID }
    }

    /// Groups `pins` so that no two resulting markers overlap on screen — the
    /// contract MapKit's rectangle collision promises but cannot sustain.
    ///
    /// Two passes. First a square grid (cell = the marker footprint in screen
    /// points, projected into map space through `zoomScale`) does the cheap
    /// bulk of the work. Then an agglomerative pass merges any two cells whose
    /// markers still touch — the boundary case a fixed grid always leaves,
    /// where two pins a hair apart fall in adjacent cells. Merging repeats to a
    /// fixed point, so a dense area collapses to one marker no matter how the
    /// grid lines happen to fall. Each marker sits at its members' centroid;
    /// after the merge no centroid has a neighbour within `cellPoints`, so the
    /// centroid can't reintroduce an overlap.
    ///
    /// - Parameters:
    ///   - cellPoints: marker collision size in screen points (side + margin).
    ///   - zoomScale: `mapView.bounds.width / mapView.visibleMapRect.size.width`.
    ///   - zoomLevel: the viewport's 0–15 zoom (`MapViewport.zoomLevel`) —
    ///     the semantic pre-pass's FALLBACK input when the corpus carries no
    ///     H3 indexes; `nil` together with no diagonal skips the pass (the
    ///     pure proximity behaviour, and what geometry-only tests exercise).
    ///   - viewportDiagonalKm: the camera viewport's diagonal, driving the
    ///     DYNAMIC banding against the ladder's H3 cell spans
    ///     (`MapHierarchyBanding`).
    static func cluster(
        _ pins: [MapPin], zoomScale: Double, cellPoints: Double,
        zoomLevel: Int32? = nil, viewportDiagonalKm: Double? = nil
    ) -> [Item] {
        // SEMANTIC PRE-PASS (STRICT nested banding): the zoom selects ONE
        // active hierarchy depth (`MapHierarchyBanding.activeKind` —
        // country or city), and hierarchy members render ONLY through that
        // depth. Every pin whose place LADDER carries an entry at the
        // active depth is absorbed into that entry's marker, however far
        // apart the members sit on screen; a pin whose ladder is non-empty
        // but has NO rung at the active depth — a country-only post while
        // the city band is up — is HIDDEN outright, never mixed in as
        // itself or through proximity. Because a city pin's ladder also
        // names its country, zooming out collapses whole cities into their
        // country's marker — the roll-up is a consequence of the ladder,
        // not a second mechanism.
        //
        // The band is exclusive exactly WHEN THE CORPUS IS HIERARCHICAL: if
        // any pin carries a ladder, everything without a rung at the active
        // depth is hidden — laddered at another level or not laddered at
        // all — so one zoom band never shows two kinds of marker. When NO
        // pin carries a ladder, the whole pass stands down and proximity
        // clustering runs untouched; that is production's permanent reality
        // today (the wire carries no place identity, BACKEND_GAPS §18), so
        // exclusivity can never blank the real map.
        //
        // Extracted BEFORE the proximity passes so a masked pin can neither
        // appear alone nor drag an unrelated pin into the place's group (a
        // gallery titled "Paris" must never open posts that did not claim
        // Paris). A group of ONE renders as a lone pin — its level's only
        // content is still that level's content — but as a standalone item,
        // never through the proximity pool.
        var maskedByPlace: [String: (place: MapPlace, members: [MapPin])] = [:]
        var unmasked: [MapPin] = []
        // Each level's characteristic H3 span, over the whole corpus (the
        // minimum where places of one kind differ) — the dynamic banding's
        // input. Empty when no rung carries an index → zoom fallback.
        var spansByKind: [MapPlace.Kind: Double] = [:]
        for pin in pins {
            for place in pin.places {
                guard let h3 = place.h3Index, let cell = H3CellGeometry(index: h3) else { continue }
                spansByKind[place.kind] = min(
                    spansByKind[place.kind] ?? .greatestFiniteMagnitude, cell.averageSpanKm
                )
            }
        }
        // `nil` means the LOCAL band — the viewer is inside the deepest
        // cell (dynamic), past the fallback's city band, or no banding
        // input was given at all (geometry-only callers): the hierarchy
        // stands down and every post renders through ordinary proximity.
        let activeKind = MapHierarchyBanding.activeKind(
            viewportDiagonalKm: viewportDiagonalKm,
            spansByKind: spansByKind,
            zoomLevel: zoomLevel
        )
        let corpusIsHierarchical = pins.contains { !$0.places.isEmpty }
        #if DEBUG
        // `-maps-banding-log`: one line per reconcile with the banding
        // decision's actual inputs — the difference between "the dynamic
        // rule chose X" and "the fallback fired because no spans arrived"
        // is invisible on screen.
        if ProcessInfo.processInfo.arguments.contains("-maps-banding-log") {
            let spans = spansByKind
                .map { "\($0.key)=\(String(format: "%.1f", $0.value))km" }
                .sorted().joined(separator: " ")
            print("[banding] pins=\(pins.count) hierarchical=\(corpusIsHierarchical)"
                + " diag=\(viewportDiagonalKm.map { String(format: "%.1f", $0) } ?? "nil")km"
                + " zoom=\(zoomLevel.map(String.init) ?? "nil")"
                + " spans=[\(spans)]"
                + " active=\(activeKind.map(String.init(describing:)) ?? "local")")
        }
        #endif
        if let activeKind, corpusIsHierarchical {
            for pin in pins {
                if let place = pin.places.first(where: { $0.kind == activeKind }) {
                    maskedByPlace[place.id, default: (place, [])].members.append(pin)
                }
                // else: no rung at the active depth — hidden, whatever else
                // the pin's ladder says (or doesn't).
            }
        } else {
            unmasked = pins
        }
        let semantic: [Item] = maskedByPlace
            .filter { $0.value.members.count > 1 }
            .sorted { $0.key < $1.key } // deterministic output order
            .map { _, group in
                let ordered = group.members.sorted { $0.postID.rawValue < $1.postID.rawValue }
                let face = representative(of: ordered)
                return Item(
                    representative: face,
                    memberIDs: [face.postID] + ordered.lazy
                        .map(\.postID)
                        .filter { $0 != face.postID },
                    // Plain averages: a place spans city blocks, not oceans,
                    // so spherical-centroid math would be precision theatre.
                    latitude: ordered.reduce(0) { $0 + $1.latitude } / Double(ordered.count),
                    longitude: ordered.reduce(0) { $0 + $1.longitude } / Double(ordered.count),
                    // The marker speaks at the ACTIVE depth: a country's
                    // group says France even though every member's leaf
                    // place is a city inside it.
                    place: group.place,
                    isHierarchyMarker: true
                )
            }
        // Groups of one render as standalone pins — OUTSIDE the proximity
        // pool, so a level's lone post can't be merged into an unladdered
        // neighbour's generic cluster and escape its band. (They still
        // collide with the band's OWN markers below — same band, no escape.)
        let lone = maskedByPlace.values.filter { $0.members.count == 1 }
            .flatMap(\.members).map(Self.single)

        guard zoomScale > 0, cellPoints > 0 else {
            return semantic + lone + unmasked.map(Self.single)
        }
        let result = collide(semantic + lone, zoomScale: zoomScale, cellPoints: cellPoints)
            + proximityCluster(unmasked, zoomScale: zoomScale, cellPoints: cellPoints)
        #if DEBUG
        // `-maps-banding-log` second line: the engine's OUTPUT — what merged
        // into what. The banding decision alone can't explain a marker the
        // collision pass produced.
        if ProcessInfo.processInfo.arguments.contains("-maps-banding-log") {
            let described = result
                .map { item in
                    "\(item.place?.id ?? "generic")×\(item.memberIDs.count)"
                        + (item.isHierarchyMarker ? "†" : "")
                        + String(format: "@(%.2f,%.2f)", item.latitude, item.longitude)
                }
                .sorted().joined(separator: " ")
            print("[banding] out: bandItems=\(semantic.count)+\(lone.count)lone"
                + " cell=\(String(format: "%.0f", cellPoints / zoomScale))mp → \(described)")
        }
        #endif
        return result
    }

    /// The band's own collision pass. The semantic pre-pass guarantees one
    /// marker per PLACE, but says nothing about where those markers land on
    /// screen: zoom out far enough and France's, Spain's and Germany's
    /// markers stack on the same few points — breaking, from the inside, the
    /// no-overlap contract this engine exists to sustain. So the active
    /// band's items (groups AND lone pins — the two pools are mutually
    /// exclusive with the proximity pool, so no band escape) run the same
    /// grid + agglomerative merge the proximity pass runs, over ITEMS
    /// instead of pins.
    ///
    /// A merged group spanning places keeps NO place identity — `place`
    /// falls to `nil`, the marker dresses neutral and its tap opens the
    /// plain viewer: a gallery titled "France" must never open Spain's
    /// posts. The face rule stays EXACT, not approximate: each item's face
    /// is already its own group's most-liked/lowest-id member, so the winner
    /// among the faces is the winner over the whole union.
    private static func collide(
        _ items: [Item], zoomScale: Double, cellPoints: Double
    ) -> [Item] {
        guard items.count > 1 else { return items }
        let cell = cellPoints / zoomScale

        // Markers being folded together; the centroid is weighted by member
        // count so the merged marker sits where its POSTS are, not at the
        // midpoint of two marker positions.
        struct Node {
            var items: [Item]
            var sumX: Double
            var sumY: Double
            var weight: Double
            var x: Double { sumX / weight }
            var y: Double { sumY / weight }
        }

        struct GridKey: Hashable { let gx: Int; let gy: Int }
        var buckets: [GridKey: Node] = [:]
        for item in items {
            let point = MKMapPoint(
                CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude)
            )
            let weight = Double(item.memberIDs.count)
            let key = GridKey(
                gx: Int((point.x / cell).rounded(.down)),
                gy: Int((point.y / cell).rounded(.down))
            )
            if buckets[key] != nil {
                buckets[key]!.items.append(item)
                buckets[key]!.sumX += point.x * weight
                buckets[key]!.sumY += point.y * weight
                buckets[key]!.weight += weight
            } else {
                buckets[key] = Node(
                    items: [item], sumX: point.x * weight, sumY: point.y * weight, weight: weight
                )
            }
        }

        // Same Chebyshev fixed-point merge as the proximity pass — the
        // markers are squares, so the collision test is the larger axis-gap.
        var nodes = Array(buckets.values)
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    let dx = abs(nodes[i].x - nodes[j].x)
                    let dy = abs(nodes[i].y - nodes[j].y)
                    if max(dx, dy) < cell {
                        nodes[i].items.append(contentsOf: nodes[j].items)
                        nodes[i].sumX += nodes[j].sumX
                        nodes[i].sumY += nodes[j].sumY
                        nodes[i].weight += nodes[j].weight
                        nodes.remove(at: j)
                        didMerge = true
                        break outer
                    }
                }
            }
        }

        return nodes.map { node in
            if node.items.count == 1 { return node.items[0] }
            // Faces ascending by id, which is what makes `representative`'s
            // "first max wins" the lowest-id tie-break over the union too.
            let faces = node.items.map(\.representative)
                .sorted { $0.postID.rawValue < $1.postID.rawValue }
            let face = representative(of: faces)
            let center = MKMapPoint(x: node.x, y: node.y).coordinate
            // Place survives only when EVERY folded marker already spoke for
            // the same place — which one band cannot produce (one marker per
            // place), so in practice a merge is generic. Kept as a rule
            // rather than an assumption, so a future caller can't silently
            // break "the gallery's title claims every member".
            let place = node.items.dropFirst().reduce(node.items[0].place) { common, item in
                common?.id == item.place?.id ? common : nil
            }
            return Item(
                representative: face,
                memberIDs: [face.postID] + node.items.lazy
                    .flatMap(\.memberIDs)
                    .filter { $0 != face.postID }
                    .sorted { $0.rawValue < $1.rawValue },
                latitude: center.latitude,
                longitude: center.longitude,
                place: place,
                isHierarchyMarker: place != nil && node.items.allSatisfy(\.isHierarchyMarker)
            )
        }
    }

    /// The screen-space passes (grid + agglomerative merge), unchanged from
    /// the pre-semantic engine.
    private static func proximityCluster(
        _ pins: [MapPin], zoomScale: Double, cellPoints: Double
    ) -> [Item] {
        // Collision distance and grid cell, both in MKMapPoints.
        let cell = cellPoints / zoomScale

        // A group being assembled: its members and their running centroid in
        // map points (kept incrementally so the merge pass stays O(1) per join).
        struct Node {
            var members: [MapPin]
            var sumX: Double
            var sumY: Double
            var x: Double { sumX / Double(members.count) }
            var y: Double { sumY / Double(members.count) }
        }

        struct GridKey: Hashable { let gx: Int; let gy: Int }
        var buckets: [GridKey: Node] = [:]
        for pin in pins {
            let point = MKMapPoint(
                CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
            )
            let key = GridKey(
                gx: Int((point.x / cell).rounded(.down)),
                gy: Int((point.y / cell).rounded(.down))
            )
            if buckets[key] != nil {
                buckets[key]!.members.append(pin)
                buckets[key]!.sumX += point.x
                buckets[key]!.sumY += point.y
            } else {
                buckets[key] = Node(members: [pin], sumX: point.x, sumY: point.y)
            }
        }

        // Merge pass: collapse any two nodes whose markers would still touch,
        // until none remain. The markers are SQUARES, so the collision test is
        // Chebyshev, not Euclidean — two squares overlap iff BOTH their x- and
        // y-gaps are under the side. Euclidean would miss the diagonal case
        // (centers a full cell apart on the diagonal still leave each axis-gap
        // at cell/√2 ≈ 0.7·cell, well inside the marker). Requiring the larger
        // axis-gap to reach a cell guarantees a real on-screen gap. Node counts
        // here are small (one per occupied cell), so the O(n²) scan is cheap.
        var nodes = Array(buckets.values)
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    let dx = abs(nodes[i].x - nodes[j].x)
                    let dy = abs(nodes[i].y - nodes[j].y)
                    if max(dx, dy) < cell {
                        nodes[i].members.append(contentsOf: nodes[j].members)
                        nodes[i].sumX += nodes[j].sumX
                        nodes[i].sumY += nodes[j].sumY
                        nodes.remove(at: j)
                        didMerge = true
                        break outer
                    }
                }
            }
        }

        return nodes.map { node in
            if node.members.count == 1 { return single(node.members[0]) }
            let ordered = node.members.sorted { $0.postID.rawValue < $1.postID.rawValue }
            let face = representative(of: ordered)
            let center = MKMapPoint(x: node.x, y: node.y).coordinate
            return Item(
                representative: face,
                // The whole group, the tapped face first — see `memberIDs`.
                // Every member is still here exactly once: the representative
                // is one of `ordered`, so removing it and re-prefixing it is a
                // rotation, not a filter.
                memberIDs: [face.postID] + ordered.lazy
                    .map(\.postID)
                    .filter { $0 != face.postID },
                latitude: center.latitude,
                longitude: center.longitude,
                place: commonPlace(of: ordered)
            )
        }
    }

    /// The place a whole group belongs to: every member tagged, and all with
    /// one id. A single untagged member — a scattered pin that merely drifted
    /// into a venue's cell at low zoom — makes the group generic: a gallery
    /// titled "Paris" must not open over posts that never claimed Paris.
    /// (The server-side rule in `BACKEND_CLUSTER_TYPES.md` aggregates before
    /// Top-K instead; this stricter client rule exists only for the mock era.)
    private static func commonPlace(of members: [MapPin]) -> MapPlace? {
        guard let first = members.first?.place else { return nil }
        return members.dropFirst().allSatisfy { $0.place?.id == first.id } ? first : nil
    }

    /// The member whose face a group wears: **the most liked, whatever kind
    /// it is** — ties fall to the lowest id, so a corpus with no counters
    /// (production until the batch hydration ran, or a failed read) degrades
    /// to the old deterministic rule rather than churning.
    ///
    /// Popularity is a POST judgement, not a format one, so this stays
    /// kind-neutral: a text post and a photograph have exactly equal claim on
    /// the face. (An earlier rule preferred members WITH a cover and was
    /// reverted — it made the symbol face unreachable for any group holding
    /// one photo. Popularity has no such reachability hole: every member can
    /// win by being liked.)
    ///
    /// The three things a marker says still agree: the face, the presentation
    /// (`MapMarkerPresentation`) and the post the feed opens on
    /// (`memberIDs.first`) are all THE SAME POST — the `memberIDs` rotation
    /// above is what guarantees "you land on what you tapped" survives any
    /// face rule, this one included. It also matches the gallery underneath:
    /// the place gallery ranks by popularity, so the face on the pin is the
    /// first tile in its grid.
    ///
    /// - Parameter ordered: the members, ascending by post id — which is what
    ///   makes "first max wins" the lowest-id tie-break.
    private static func representative(of ordered: [MapPin]) -> MapPin {
        ordered.dropFirst().reduce(ordered[0]) { best, pin in
            pin.likeCount > best.likeCount ? pin : best
        }
    }

    private static func single(_ pin: MapPin) -> Item {
        Item(
            representative: pin, memberIDs: [pin.postID],
            latitude: pin.latitude, longitude: pin.longitude, place: pin.place
        )
    }
}

/// The `MKAnnotation` for an engine-computed group. Coordinate is KVO-observed
/// so a centroid shift moves the marker without a remove/add cycle, and it
/// carries its member ids so a tap opens the whole group with no round-trip.
///
/// Identity is the OBJECT, not any of its contents. `MapClusterTracker` keeps a
/// group's marker alive across reconciles even as its representative and
/// membership shift, so `apply(_:)` mutates all of those in place — and MapKit
/// hashes annotations to track them, so a content-derived hash that changed
/// under a live marker would corrupt the map's internal set. Object identity is
/// stable for the marker's whole life on the map.
final class MapComputedCluster: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    private(set) var representative: MapPin
    private(set) var memberIDs: [PostID]
    /// The group's common place, when it has one — what routes a tap to the
    /// gallery-backed presentation (Case B). See `MapClusterEngine.Item.place`.
    private(set) var place: MapPlace?
    /// Whether this marker is the active band's own (see
    /// `MapClusterEngine.Item.isHierarchyMarker`) — what the hierarchy ring
    /// colors key on.
    private(set) var isHierarchyMarker = false

    init(_ item: MapClusterEngine.Item) {
        self.representative = item.representative
        self.memberIDs = item.memberIDs
        self.place = item.place
        self.isHierarchyMarker = item.isHierarchyMarker
        self.coordinate = CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude)
        super.init()
    }

    /// Re-points and re-populates an existing marker for a recomputed layout.
    func apply(_ item: MapClusterEngine.Item) {
        representative = item.representative
        memberIDs = item.memberIDs
        place = item.place
        isHierarchyMarker = item.isHierarchyMarker
        let next = CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude)
        if next.latitude != coordinate.latitude || next.longitude != coordinate.longitude {
            coordinate = next
        }
    }
}
