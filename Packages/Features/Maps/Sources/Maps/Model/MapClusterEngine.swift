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
        /// untagged group. Set on singles too (the pin's own tag — or, for a
        /// band's group of one, the band's place), but routing keys on
        /// `hierarchyPlace`: an ordinary lone pin is Case A whatever it is
        /// tagged with, a band's group of one is its place's marker.
        let place: MapPlace?
        /// Whether this item was produced BY the semantic pre-pass — i.e. it
        /// is the active band's marker for its place. Only these wear the
        /// hierarchy ring colors: a LOCAL-band proximity cluster that happens
        /// to share a leaf place keeps its gallery tap (`isSemanticCluster`)
        /// but dresses neutral, because below the city band everything on
        /// screen is ordinary local content.
        var isHierarchyMarker = false

        /// The depth this marker speaks for — what its dress keys on
        /// (`MapMarkerDress.resolve(kind:)`) — or nil below the bands. A
        /// band's group of one has one too: it wears its place's dress.
        var hierarchyKind: MapPlace.Kind? { hierarchyPlace?.kind }

        /// The city or country this marker IS — what its tap opens as a place
        /// page beneath the feed — or nil below the bands. A band's group of
        /// ONE has one too: a country with a single post in view is still that
        /// country's marker, and it routes exactly like a band cluster
        /// (product call, 2 October 2026 — the mock world's one-post countries
        /// dismissed onto the map while Paris dismissed onto its page).
        var hierarchyPlace: MapPlace? { isHierarchyMarker ? place : nil }

        var isCluster: Bool { memberIDs.count > 1 }

        /// A multi-post group whose members all share one place. An engine
        /// FACT, not a routing decision: since 2026-08-31 only HIERARCHY
        /// markers (`isHierarchyMarker` — the band's own city/country
        /// clusters) open the place page behind their feed; a proximity
        /// cluster that happens to share a leaf place stays a plain feed.
        var isSemanticCluster: Bool { isCluster && place != nil }

        /// The representative's id. Note this is NOT a stable marker identity: a
        /// cluster's representative churns as the Top-K set shifts, which is
        /// exactly why the map layer tracks clusters by membership overlap
        /// (`MapClusterTracker`) rather than keying off this.
        var key: PostID { representative.postID }
    }

    /// What the band's occlusion pass carries from one layout to the next —
    /// the caller keeps it (`MapsViewController`) and hands it back on every
    /// reconcile. See `occlude`.
    struct Occlusion: Equatable {
        /// The band markers the last layout HID, by `BandEntry.key` — the
        /// hysteresis input: a marker hidden last time needs `reappearMargin`
        /// times the room to come back.
        var hiddenKeys: Set<String> = []
        /// The band markers the last layout hid, whole. Not drawn, but their
        /// posts are still on the map's books: a hidden country is not an
        /// EMPTY country, so it must not wear an empty country's flag disc.
        var hiddenItems: [Item] = []
    }

    /// How much more room than a cell a HIDDEN band marker needs before it
    /// comes back. Strictly above the snap step (`snapZoom`, 2^0.25 ≈ 1.19):
    /// a pinch hovering on one step boundary flips the cell by exactly that
    /// ratio, so any smaller margin would let a pair sitting between the two
    /// cells hide and show on every crossing.
    static let reappearMargin = 1.25

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
    /// The zoom the grid is actually computed at — quarter-octave steps,
    /// rounded DOWN.
    ///
    /// ⚠️ THE GRID HAD NO HYSTERESIS AT ALL. `cell = cellPoints / zoomScale`
    /// with buckets at absolute map-point origins means one ulp of
    /// `visibleMapRect` moves every grid line AND the merge threshold at once
    /// — and MapKit's region↔rect round-trip is lossy, so the first read after
    /// the map is re-attached need not be bit-identical to the last one before
    /// it. That is enough to re-partition a corpus nothing has changed.
    ///
    /// DOWNWARD on purpose: the cell only ever grows, by at most 2^0.25 ≈ 19%,
    /// so the merge threshold never shrinks and the no-overlap contract the
    /// suite pins cannot be broken by the snap. A real pinch crosses several
    /// steps in a fraction of a gesture; an epsilon crosses none.
    static func snapZoom(_ zoomScale: Double) -> Double {
        guard zoomScale > 0, zoomScale.isFinite else { return 0 }
        return exp2((log2(zoomScale) * 4).rounded(.down) / 4)
    }

    static func cluster(
        _ pins: [MapPin], zoomScale: Double, cellPoints: Double,
        zoomLevel: Int32? = nil, viewportDiagonalKm: Double? = nil,
        isOpen: (MapPin) -> Bool = { _ in true }
    ) -> [Item] {
        var occlusion = Occlusion()
        return cluster(
            pins, zoomScale: zoomScale, cellPoints: cellPoints,
            zoomLevel: zoomLevel, viewportDiagonalKm: viewportDiagonalKm,
            isOpen: isOpen, occlusion: &occlusion
        )
    }

    /// `cluster`, carrying the band's occlusion state across layouts — the
    /// map's entry point. Stateless callers (tests, one-shot layouts) take
    /// the overload above, which starts from nothing hidden.
    ///
    /// - Parameters:
    ///   - isOpen: whether a pin's post may be opened by the viewer (its
    ///     country is unlocked). Open and locked posts are NEVER grouped
    ///     together — a marker is one tap: it opens everything it holds, or it
    ///     offers a country — and at a band an open marker always wins a
    ///     collision against a locked one.
    ///   - occlusion: what the last layout hid; updated to what this one hides.
    static func cluster(
        _ pins: [MapPin], zoomScale: Double, cellPoints: Double,
        zoomLevel: Int32? = nil, viewportDiagonalKm: Double? = nil,
        isOpen: (MapPin) -> Bool = { _ in true },
        occlusion: inout Occlusion
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
        // Keyed by place AND openness: a place's open and locked posts (a
        // locked country's offshore pin reads as open) are two markers, never
        // one — see `isOpen`.
        var maskedByPlace: [String: (place: MapPlace, isOpen: Bool, members: [MapPin])] = [:]
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
                    let open = isOpen(pin)
                    let key = open ? place.id : place.id + "#locked"
                    maskedByPlace[key, default: (place, open, [])].members.append(pin)
                }
                // else: no rung at the active depth — hidden, whatever else
                // the pin's ladder says (or doesn't).
            }
        } else {
            unmasked = pins
        }
        let semantic: [BandEntry] = maskedByPlace
            .filter { $0.value.members.count > 1 }
            .sorted { $0.key < $1.key } // deterministic output order
            .map { key, group in
                let ordered = group.members.sorted { $0.postID.rawValue < $1.postID.rawValue }
                let face = representative(of: ordered)
                return BandEntry(key: key, isOpen: group.isOpen, item: Item(
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
                ))
            }
        // Groups of one render as standalone pins — OUTSIDE the proximity
        // pool, so a level's lone post can't be merged into an unladdered
        // neighbour's generic cluster and escape its band. (They still
        // contend with the band's OWN markers below — same band, no escape.)
        // ⚠️ SORTED, like `semantic` above and for its stated reason: the
        // occlusion pass's tie-break and output order must be a function of
        // the input alone, not of a dictionary's iteration order.
        //
        // A group of one is still its place's marker: it speaks at the ACTIVE
        // depth (France, not Paris) and is a hierarchy marker, so it wears the
        // place's dress like any band cluster — at the country band only
        // countries, at the city band only cities, even with one post in view.
        // And it ROUTES like one (`hierarchyPlace`): its feed has one post,
        // and a vertical dismissal lands on the place page all the same.
        let lone: [BandEntry] = maskedByPlace.filter { $0.value.members.count == 1 }
            .sorted { $0.value.members[0].postID.rawValue < $1.value.members[0].postID.rawValue }
            .map { key, group in
                let pin = group.members[0]
                return BandEntry(key: key, isOpen: group.isOpen, item: Item(
                    representative: pin, memberIDs: [pin.postID],
                    latitude: pin.latitude, longitude: pin.longitude,
                    place: group.place, isHierarchyMarker: true
                ))
            }

        guard zoomScale > 0, cellPoints > 0 else {
            occlusion = Occlusion()
            return (semantic + lone).map(\.item) + unmasked.map(Self.single)
        }
        let band = occlude(
            semantic + lone, zoomScale: zoomScale, cellPoints: cellPoints, occlusion: &occlusion
        )
        // The proximity pool (the local band, or a corpus with no ladder at
        // all) keeps its own rules: open and locked posts are still grouped
        // APART, and where their markers collide MapKit keeps the open one
        // (`MapMarkerDress.lockedPriority`).
        let result = band
            + proximityCluster(unmasked.filter(isOpen), zoomScale: zoomScale, cellPoints: cellPoints)
            + proximityCluster(unmasked.filter { !isOpen($0) }, zoomScale: zoomScale, cellPoints: cellPoints)
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
            let hidden = occlusion.hiddenKeys.sorted().joined(separator: " ")
            print("[banding] out: bandItems=\(semantic.count)+\(lone.count)lone"
                + " cell=\(String(format: "%.0f", cellPoints / zoomScale))mp → \(described)"
                + " hidden=[\(hidden)]")
        }
        #endif
        return result
    }

    /// One band marker contending for its spot on screen: the item, the key
    /// that identifies it across layouts (its place, and whether it is the
    /// place's open or locked side), and whether the viewer may open it.
    private struct BandEntry {
        let key: String
        let isOpen: Bool
        let item: Item
    }

    /// The band's own collision pass. The semantic pre-pass guarantees one
    /// marker per PLACE, but says nothing about where those markers land on
    /// screen: zoom out far enough and France's, Spain's and Germany's
    /// markers would stack on the same few points.
    ///
    /// ⚠️ PLACES ARE NEVER MERGED. This pass used to fold colliding band
    /// markers into one group that spoke for no place (`place == nil`): a
    /// neutral marker in the middle of the country band, the one thing the
    /// band exists to rule out (Arnaud, 2026-10-01: "at the country level I
    /// should only see countries, at the city level only cities"). Instead a
    /// band marker that would overlap a STRONGER one is HIDDEN until the zoom
    /// gives it room — the way Apple's map labels give way.
    ///
    /// Strength, in order: an OPEN marker beats a locked one (what the viewer
    /// can open is never covered by what they cannot); then the most
    /// TRENDING — its face's like count, the face being the place's most liked
    /// post; then the lowest face id, then the key, so the answer is a function
    /// of the input alone. Greedy, strongest first: a marker hidden by a
    /// stronger one hides nothing itself.
    ///
    /// Hysteresis: a marker the LAST layout hid needs `reappearMargin` times a
    /// cell of clearance to come back, while a shown one stays until it truly
    /// overlaps. Positions are map points (zoom-independent) and the cell is
    /// snapped, so a pan never changes the answer; a pinch parked on a snap
    /// boundary cannot toggle a pair either (see `reappearMargin`).
    ///
    /// Shown markers still keep the no-overlap contract — every pair is at
    /// least a cell apart — so MapKit's own collision (open `.required`,
    /// locked `MapMarkerDress.lockedPriority`) never has a band overlap left
    /// to arbitrate, and cannot hide something this pass chose to show.
    private static func occlude(
        _ entries: [BandEntry], zoomScale: Double, cellPoints: Double, occlusion: inout Occlusion
    ) -> [Item] {
        let cell = cellPoints / zoomScale
        let ranked = entries.sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            let likesA = a.item.representative.likeCount, likesB = b.item.representative.likeCount
            if likesA != likesB { return likesA > likesB }
            let faceA = a.item.representative.postID.rawValue, faceB = b.item.representative.postID.rawValue
            if faceA != faceB { return faceA < faceB }
            return a.key < b.key
        }
        var shown: [MKMapPoint] = []
        var hiddenKeys = Set<String>()
        for entry in ranked {
            let point = MKMapPoint(
                CLLocationCoordinate2D(latitude: entry.item.latitude, longitude: entry.item.longitude)
            )
            // Chebyshev, as everywhere in this engine: the markers are squares.
            let clearance = occlusion.hiddenKeys.contains(entry.key) ? cell * reappearMargin : cell
            if shown.contains(where: { max(abs($0.x - point.x), abs($0.y - point.y)) < clearance }) {
                hiddenKeys.insert(entry.key)
            } else {
                shown.append(point)
            }
        }
        occlusion = Occlusion(
            hiddenKeys: hiddenKeys,
            hiddenItems: entries.filter { hiddenKeys.contains($0.key) }.map(\.item)
        )
        // The input's own (deterministic) order, not the ranking's.
        return entries.filter { !hiddenKeys.contains($0.key) }.map(\.item)
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
        // ⚠️ ORDER IS LOAD-BEARING HERE, not incidental. This is a
        // centroid-updating single-linkage fixed point: `nodes[i]` absorbs
        // `nodes[j]` and the centroid MOVES, so whether a third node still
        // falls within a cell depends on which pair merged first. Taken from a
        // dictionary's values it changed whenever the dictionary was mutated,
        // which is every query — so returning to the map re-partitioned pins
        // that had not moved. Keyed traversal makes the answer a function of
        // the input alone.
        var nodes = buckets.keys.sorted { ($0.gx, $0.gy) < ($1.gx, $1.gy) }
            .map { buckets[$0]! }
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

    /// See `MapClusterEngine.Item.hierarchyPlace`.
    var hierarchyPlace: MapPlace? { isHierarchyMarker ? place : nil }

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
