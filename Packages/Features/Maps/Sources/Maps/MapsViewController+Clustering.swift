import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import LocalStore
import MapKit
import MapsInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

// Querying and clustering (#2388, out of the map's file)
extension MapsViewController {
    // MARK: - Querying

    func scheduleQuery() {
        pendingQuery?.cancel()
        // Nothing to fetch for the guest without location: they roam the
        // countries' own layer (#564, #1907). Unlocking flies somewhere, and
        // that settle queries.
        guard !isGuestLocked else { return }
        let work = DispatchWorkItem { [weak self] in self?.runQuery() }
        pendingQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func runQuery() {
        let region = mapView.region
        let viewport = MapViewport.make(
            centerLat: region.center.latitude,
            centerLng: region.center.longitude,
            latitudeSpan: region.span.latitudeDelta,
            longitudeSpan: region.span.longitudeDelta
        )
        viewModel.viewportChanged(viewport)
    }

    // MARK: - Clustering

    /// Re-lays-out the map from the current pin model: `MapClusterEngine`
    /// decides the markers (a `MapAnnotation` per lone pin, a
    /// `MapComputedCluster` per group), and this reconciles them against
    /// what's on screen — updating a surviving marker in place, adding the new,
    /// removing the gone.
    ///
    /// This replaces `MKMapView`'s own clustering, which degrades irreparably
    /// across pan+zoom (see `MapClusterEngine`): the map is handed finished
    /// markers with no `clusteringIdentifier`, so MapKit never runs the pass
    /// that breaks — it just draws each one where we place it.
    ///
    /// Stable markers are LEFT ON THE MAP and updated in place — never removed
    /// and re-added — so they don't flicker. Singles key off their post id
    /// (stable by nature); clusters are matched to the marker they most overlap
    /// (`MapClusterTracker`), because a cluster's representative churns as the
    /// Top-K set shifts and keying off it would fade a settled cluster out and a
    /// near-identical one back in.
    func reconcileClusters() {
        #if DEBUG
        MapChurnCounters.reconciles += 1
        let reconcileStart = DispatchTime.now().uptimeNanoseconds
        let pinFingerprint = pins.count &* 31 &+ (pins.keys.first?.rawValue.hashValue ?? 0)
        if pinFingerprint == lastReconciledPinFingerprint { MapChurnCounters.withUnchangedPins += 1 }
        lastReconciledPinFingerprint = pinFingerprint
        defer {
            MapChurnCounters.recordReconcile(
                micros: Int((DispatchTime.now().uptimeNanoseconds - reconcileStart) / 1_000)
            )
        }
        #endif
        // ⚠️ A ZERO SCALE IS NOT A ZOOM, IT IS A NOT-YET. The engine's own
        // degenerate path ships EVERY pin as an unclustered single, and this
        // runs from `regionDidChangeAnimated`, which fires when the map is
        // re-attached — so one reconcile against a rect that has not resolved
        // exploded the whole map to member coordinates and re-collapsed a frame
        // later. Deferred instead: `layoutPending` is what the next real
        // layout drains.
        guard currentZoomScale > 0 else {
            layoutPending = true
            return
        }
        #if DEBUG
        // `-maps-no-clustering`: every pin becomes its own marker.
        //
        // ⚠️ It exists because the SHIPPING map cannot produce its own designed
        // worst case. `MapClusterEngine`'s proximity merge recomputes each
        // cluster's centroid, so merges CHAIN and a dense uniform field
        // collapses instead of packing the 64pt lattice — measured invariant at
        // 19 markers whether the corpus is fed 5x, 15x or 40x. The 128-marker
        // figure every budget in this feature is sized against is a GEOMETRIC
        // bound, and this flag is the only way to stand a field of that size in
        // front of the real renderer.
        //
        // It is not a product mode and must never become one: without the merge
        // the map has no answer for a dense city.
        let unclustered = ProcessInfo.processInfo.arguments.contains("-maps-no-clustering")
        #else
        let unclustered = false
        #endif

        // ⚠️ SORTED, because the proximity merge downstream is order-dependent
        // (see `proximityCluster`). A dictionary's values re-order whenever it is mutated, and
        // every return to this screen re-queries — so the markers moved on a map
        // nobody had panned.
        let ordered = pins.values.sorted { $0.postID.rawValue < $1.postID.rawValue }
        // ⚠️ OPEN AND LOCKED POSTS ARE NEVER GROUPED TOGETHER.
        //
        // A locked country's posts are on the map — its markers wear its
        // busiest posts, darkened under a lock — but a marker is ONE tap: it
        // opens every post it holds, or it offers a country. A group mixing
        // the two would either open locked posts or lock open ones. The engine
        // groups each side apart (`isOpen`); at a hierarchy band it also
        // decides their collisions — the open marker stays, the locked one is
        // hidden — and below the bands MapKit does (`MapMarkerDress
        // .lockedPriority`).
        let items = layOut(ordered, unclustered: unclustered)
        // A country whose marker is HIDDEN behind a stronger neighbour still
        // has posts: it is not an empty country, so it wears no flag disc.
        reportCountriesWithMarkers(items + bandOcclusion.hiddenItems)
        reconcile(items)
    }

    /// Tells the country layer which countries a post marker now stands for —
    /// every member's, so a country whose posts merged into a neighbour's
    /// marker does not also wear an empty country's disc.
    private func reportCountriesWithMarkers(_ items: [MapClusterEngine.Item]) {
        var codes = Set<String>()
        for item in items {
            for id in item.memberIDs {
                guard let pin = pins[id] else { continue }
                let code = countryCode(of: pin)
                if !code.isEmpty { codes.insert(code) }
            }
        }
        countryLayer.setCountriesWithMarkers(codes)
    }

    /// Reconciles `items` — the engine's layout — against the markers on the
    /// map. See `reconcileClusters`.
    private func reconcile(_ items: [MapClusterEngine.Item]) {
        var target = Set<String>()
        target.reserveCapacity(items.count)
        var toAdd: [MKAnnotation] = []

        // Singles: one pin, one identity — reuse or reclaim by post id.
        for item in items where !item.isCluster {
            let id = Self.singleIdentity(item.representative.postID)
            target.insert(id)
            if let existing = displayed[id] {
                update(existing, to: item)
            } else if let reclaimed = popChoreographer.reclaim(id) {
                update(reclaimed, to: item)
                displayed[id] = reclaimed
            } else {
                let annotation = Self.makeAnnotation(for: item)
                displayed[id] = annotation
                toAdd.append(annotation)
            }
        }

        // Clusters: match by shared membership so a marker persists through the
        // representative churn. Candidates are the shown clusters PLUS the ones
        // still fading out — matching a returning cluster to a departing marker
        // reclaims it instead of stacking a duplicate.
        let clusterItems = items.filter(\.isCluster)
        var candidates: [MapClusterTracker.Candidate] = []
        var candidateIsDeparting: [String: Bool] = [:]
        for (key, annotation) in displayed {
            guard let cluster = annotation as? MapComputedCluster else { continue }
            candidates.append(.init(key: key, members: Set(cluster.memberIDs)))
            candidateIsDeparting[key] = false
        }
        for (key, annotation) in popChoreographer.departingMarkers {
            guard let cluster = annotation as? MapComputedCluster else { continue }
            candidates.append(.init(key: key, members: Set(cluster.memberIDs)))
            candidateIsDeparting[key] = true
        }
        // ⚠️ SORTED BEFORE THE ASSIGN. `MapClusterTracker.assign` documents a
        // tie-break on the CANDIDATE INDEX — which is only deterministic if
        // the caller supplies a defined one, and both loops above walk
        // dictionaries.
        candidates.sort { $0.key < $1.key }

        let matches = MapClusterTracker.assign(
            incoming: clusterItems.map { Set($0.memberIDs) }, candidates: candidates
        )
        for (item, matchedKey) in zip(clusterItems, matches) {
            if let key = matchedKey {
                target.insert(key)
                if candidateIsDeparting[key] == true, let reclaimed = popChoreographer.reclaim(key) {
                    update(reclaimed, to: item)
                    displayed[key] = reclaimed
                } else if let existing = displayed[key] {
                    update(existing, to: item)
                }
            } else {
                clusterMarkerSeq += 1
                let key = "c:\(clusterMarkerSeq)"
                let annotation = Self.makeAnnotation(for: item)
                displayed[key] = annotation
                toAdd.append(annotation)
                target.insert(key)
            }
        }

        // Departures: the still-shown markers no target claimed. Hand them to
        // the choreographer to scale-and-fade out (mirroring the arrival),
        // which removes them from the map when the animation ends. They leave
        // `displayed` now — the choreographer is their sole owner until then.
        let departing = displayed.filter { !target.contains($0.key) }
        for id in departing.keys { displayed[id] = nil }
        // A marker that leaves before its view was ever realized is no longer
        // an arrival, and its identifier would otherwise sit in the set for the
        // life of the screen.
        for annotation in departing.values {
            pendingPopIn.remove(ObjectIdentifier(annotation as AnyObject))
        }
        popChoreographer.popOut(departing.map { (id: $0.key, annotation: $0.value) })

        #if DEBUG
        MapChurnCounters.added += toAdd.count
        MapChurnCounters.departed += departing.count
        #endif
        if !toAdd.isEmpty {
            pendingPopIn.formUnion(toAdd.map { ObjectIdentifier($0 as AnyObject) })
            mapView.addAnnotations(toAdd)
        }
        refreshVideoPlayback()
    }

    /// The engine's layout of `ordered` (see `reconcileClusters`).
    /// Singles go through the SAME reconciliation, so what
    /// `-maps-no-clustering` measures is the real marker lifecycle and not a
    /// parallel code path that happens to look similar.
    private func layOut(_ ordered: [MapPin], unclustered: Bool) -> [MapClusterEngine.Item] {
        // Nothing goes through the band: nothing is hidden behind anything.
        if ordered.isEmpty || unclustered { bandOcclusion = MapClusterEngine.Occlusion() }
        guard !ordered.isEmpty else { return [] }
        // The ceiling reads the bands from the same spans (#1907).
        depthClamp.spans = MapClusterEngine.spansByKind(of: ordered)
        return unclustered
            ? ordered.map {
                MapClusterEngine.Item(
                    representative: $0, memberIDs: [$0.postID],
                    latitude: $0.latitude, longitude: $0.longitude, place: $0.place
                )
            }
            : MapClusterEngine.cluster(
                ordered,
                // Snapped, so an epsilon in the viewport cannot move every grid
                // line at once — see `MapClusterEngine.snapZoom`.
                zoomScale: MapClusterEngine.snapZoom(currentZoomScale),
                cellPoints: Double(Self.clusterCellPoints),
                // The semantic pre-pass's two banding inputs: the zoom level is
                // the FALLBACK for an H3-less corpus; the viewport diagonal
                // drives the dynamic cell-span rule (`MapHierarchyBanding`)
                // whenever the ladder carries H3 indexes.
                zoomLevel: MapViewport.zoomLevel(
                    forLongitudeSpan: mapView.region.span.longitudeDelta
                ),
                viewportDiagonalKm: currentViewportDiagonalKm,
                isOpen: { self.isInUnlockedCountry($0) },
                occlusion: &bandOcclusion
            )
    }

    static func singleIdentity(_ postID: PostID) -> String { "p:" + postID.rawValue }

    /// The marker a FRESH engine item becomes — a group's cluster, or a lone
    /// pin carrying its band's place when it is one (`hierarchyPlace`).
    /// Static so the tests build markers the way the map does, and route them
    /// through the same `hierarchyPlace(of:)` a tap asks.
    static func makeAnnotation(for item: MapClusterEngine.Item) -> any MKAnnotation {
        item.isCluster
            ? MapComputedCluster(item)
            : MapAnnotation(pin: item.representative, hierarchyPlace: item.hierarchyPlace)
    }

    /// Splits a batch of realized views into the ones that are ARRIVING and the
    /// ones that are merely being drawn again.
    ///
    /// Pure and static for the same reason `stack(_:inserting:beneath:)` is:
    /// the rule needs no live `MKMapView`, and getting it wrong is invisible in
    /// a screenshot — it only shows up as a map that re-lands every time the
    /// viewer comes back to it.
    static func popPartition<View>(
        _ views: [View], pending: Set<ObjectIdentifier>,
        identity: (View) -> ObjectIdentifier?
    ) -> (arriving: [View], settled: [View]) {
        var arriving: [View] = []
        var settled: [View] = []
        for view in views {
            if let id = identity(view), pending.contains(id) {
                arriving.append(view)
            } else {
                settled.append(view)
            }
        }
        return (arriving, settled)
    }

    /// The place page's way home: a closure producing a FRESH flight source
    /// for `annotation`'s marker, resolved when the page stages its own
    /// dismissal — the marker's face, ring and even presence can all have
    /// changed since the tap, so nothing is captured beyond the annotation's
    /// identity. `nil` when the marker has left the map entirely, which is
    /// the page's cue to keep the plain slide (the fallback dismissal).
    /// `departureStill` draws the screen the flight is leaving — see the seam's
    /// own doc. Asked at STAGING, so it costs one render on the first frame of
    /// the gesture and nothing at all when the flight never happens.
    func makeMapReturnSource(
        for annotation: any MKAnnotation
    ) -> (@escaping () -> UIImage?) -> (any ZoomTransitionSource)? {
        { [weak self, weak box = annotation as AnyObject] departureStill in
            guard let self, let box, let annotation = box as? any MKAnnotation,
                  self.mapView.annotations.contains(where: { ($0 as AnyObject) === box })
            else { return nil }
            let view = self.mapView.view(for: annotation)
            let thumbnail = (view as? MapClusterAnnotationView)?.heroImage
                ?? (view as? MapAnnotationView)?.heroImage
            let cluster = annotation as? MapComputedCluster
            return MapPinZoomSource(
                mapView: self.mapView,
                annotation: annotation,
                thumbnail: thumbnail,
                face: Self.face(of: annotation),
                dress: self.dress(for: annotation),
                // ⚠️ THE WHOLE DEPARTING SCREEN, not a post's cover. Every other
                // departure on this source is one post leaving another; here a
                // GRID is collapsing into an icon, and without an operand the
                // card wore that icon from the first frame — a full-screen page
                // cutting straight to a 44pt disc with nothing carried across.
                //
                // Resolved through the same channel a post's picture uses, so
                // the blend does not learn a second shape.
                departureCover: { departureStill().map { .picture($0) } ?? .none }
            )
        }
    }

    /// The place page's way home as a WINDOW onto the marker — the close a
    /// text post opened from that marker already takes (`markerRevealOrigin`).
    ///
    /// ⚠️ NOT THE HERO. The page used to fly home through `MapPinZoomSource`,
    /// whose card is the MARKER's face: under a grab the page was hidden
    /// outright and a marker-shaped sliver of it rode the finger over a black
    /// screen (filmed, 26 September 2026). A window keeps the page itself
    /// under the finger, shrinks it as it is dragged, and closes it onto the
    /// marker with the reveal's crossfade — "prendre le contenu de la fenêtre
    /// de lieu actuelle et au release faire notre hero transition habituelle".
    ///
    /// Asked at close time, so the marker's rect is where the map shows it
    /// now; nil once the marker is gone, which keeps the plain slide.
    func makeMarkerClose(
        for annotation: any MKAnnotation
    ) -> (UIViewController) -> RevealGeometry? {
        { [weak self, weak box = annotation as AnyObject] page in
            guard let self, let box, let annotation = box as? any MKAnnotation,
                  self.mapView.annotations.contains(where: { ($0 as AnyObject) === box })
            else { return nil }
            // No "will close" chrome work: unlike a feed, the place page
            // SHOWS the dock (`concealsAppTabBar == false`), so there is
            // nothing to hide ahead of the window and nothing to bring back.
            return self.makeRevealGeometry(page, self.markerRevealOrigin(for: annotation), nil)
        }
    }
}
