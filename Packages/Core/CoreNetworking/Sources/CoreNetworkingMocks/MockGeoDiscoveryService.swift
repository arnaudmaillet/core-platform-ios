import Connect
import CoreContracts
import Foundation

/// Fake of geo_discovery.v1.GeoDiscoveryService over the shared dataset. Radar
/// path only for now (QueryTile) — the Focus path (GetGeoTimeline) arrives with
/// the Maps tap/hero transition in Step B.
///
/// The mock dataset has no coordinates, so pins are scattered deterministically
/// around central Paris (matching the map's default region) from the post's
/// index. **Every** post is indexed, media or not: a text-only post is a pin
/// with an empty `thumbnail_url`, which is the only way `RadarPin` can say "no
/// cover" and is what the client classifies as a text marker. The scatter is
/// keyed on the post's index in the corpus, not on its position among the
/// mapped subset, so which posts are indexed does not move the others.
/// The result is filtered to the requested viewport and Top-K capped, so pan/
/// zoom and clustering behave like the real service without a fleet.
///
/// On top of that scatter sit three VENUES — addresses whose posts share one
/// exact coordinate, mixing kinds on purpose. Without them the fixture had a
/// property no real corpus has: every post at a distinct point, so nothing ever
/// clustered until the viewer zoomed out. See `venueAssignments`.
public final class MockGeoDiscoveryService: @unchecked Sendable {
    private let dataset: MockSocialDataset
    /// Posts pinned to a shared VENUE coordinate — see `venueAssignments`.
    private let venues: [String: Venue]

    /// Central Paris — the map's default region centers here.
    private static let baseLat = 48.8566
    private static let baseLng = 2.3522
    /// Scatter radius in degrees (~±16 km), enough to exercise pan and clustering.
    private static let spread = 0.15
    /// Per-response cap, standing in for the server's per-tile Top-K.
    private static let topK = 80

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
        self.venues = Self.venueAssignments(for: dataset.posts)
    }

    // MARK: - Venues

    /// A place several posts were published FROM, at one identical coordinate.
    struct Venue: Sendable {
        let name: String
        let lat: Double
        let lng: Double
    }

    /// Three addresses inside the map's opening viewport (±0.045° of centre),
    /// spaced well beyond one collision cell (~0.014° at that zoom) so they
    /// stay three separate markers rather than merging into one.
    ///
    /// The scatter alone gives every post its own coordinate — measured: at the
    /// default region, 10 pins produce 10 markers and ZERO clusters, and no two
    /// posts anywhere share a coordinate. Clusters therefore only appeared when
    /// zoomed out, which made "tap a marker, get one post" look like a rule
    /// about text posts when it was really a rule about lone pins. Real corpora
    /// are not like that: a café, a venue, a viewpoint accumulates posts at one
    /// address, of every kind.
    ///
    /// The three exist to make each case reachable at the zoom the app opens at:
    /// - `mixed` — text AND media at one address. Its face is whichever kind
    ///   its lowest-id member is (the representative is kind-neutral), and the
    ///   tap opens all of them, both kinds, in one swipeable feed.
    /// - `textOnly` — an address with nothing but words, so the all-text case
    ///   is pinned deterministically rather than left to id arithmetic.
    /// - `mediaOnly` — the control, so the other two can be read as "same
    ///   machinery, different contents" rather than as special cases.
    static let mixedVenue = Venue(name: "mixed", lat: 48.8640, lng: 2.3400)
    static let textOnlyVenue = Venue(name: "text-only", lat: 48.8480, lng: 2.3660)
    static let mediaOnlyVenue = Venue(name: "media-only", lat: 48.8500, lng: 2.3380)

    /// Walks the corpus in order and hands the first few posts of each kind to
    /// a venue, so the assignment is deterministic and survives a reseed.
    ///
    /// ⚠️ This is the ONE place in the pipeline that reads a post's kind to
    /// decide where it goes, and it is a fixture: the point is to co-locate
    /// kinds deliberately so the client's kind-BLIND clustering has something
    /// to prove itself on. Nothing downstream — not the tile query, not the
    /// engine — asks what a post is in order to group it.
    private static func venueAssignments(for posts: [MockSocialDataset.PostRecord]) -> [String: Venue] {
        var assignments: [String: Venue] = [:]
        var text = posts.lazy.filter { $0.media == nil }.map(\.postID).makeIterator()
        var media = posts.lazy.filter { $0.media != nil }.map(\.postID).makeIterator()
        func assign(_ venue: Venue, text textCount: Int, media mediaCount: Int) {
            for _ in 0..<textCount { if let id = text.next() { assignments[id] = venue } }
            for _ in 0..<mediaCount { if let id = media.next() { assignments[id] = venue } }
        }
        assign(mixedVenue, text: 2, media: 3)
        assign(textOnlyVenue, text: 3, media: 0)
        assign(mediaOnlyVenue, text: 0, media: 3)
        return assignments
    }

    /// What a pin puts in its single `thumbnail_url` field.
    ///
    /// `RadarPin` has exactly one URL and no media kind, which is the gap
    /// `dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §C exists to close: a
    /// video pin has nowhere to say "this is a video, here is a cheap loop".
    /// The client therefore renders every pin through the image pipeline unless
    /// `-maps-force-video` is on, so this has to follow the same rule:
    ///
    /// - Default — a **still**. Under `.realAssets` a video post's media URL is
    ///   an HLS manifest or an MP4, which the image pipeline cannot decode, so
    ///   it is swapped for a real photograph. Handing the raw video URL over
    ///   here renders a blank pin, which is a fixture bug, not a finding.
    /// - Under `-maps-force-video` — the lightweight **preview loop**, never
    ///   the full stream. A pin must not be able to open an HLS ladder mid-pan,
    ///   which is the whole point of the contract ask. Its `mock-kind=video`
    ///   marker is what `GeoDiscoveryRepository.kind(for:)` matches on.
    static func pinURL(forMediaURL url: String, catalog: MockSocialDataset.MediaCatalog) -> String {
        guard catalog == .realAssets, MockMediaFixtures.isVideoURL(url) else { return url }
        return forcesMapVideo
            ? MockMediaFixtures.mapPreviewLoop.url
            : MockMediaFixtures.imageURL(index: url.count, width: 256, height: 256)
    }

    /// Mirrors the Maps feature's own DEBUG launch argument. Read here so the
    /// fixture a pin carries matches how the client will classify it.
    static let forcesMapVideo = ProcessInfo.processInfo.arguments.contains("-maps-force-video")

    public func register(on bff: MockBFF) {
        bff.register(path: "/geo_discovery.v1.GeoDiscoveryService/QueryTile") { [self] (request: GeoDiscovery_V1_QueryTileRequest, headers: Headers) in
            queryTile(request, filter: headers[Self.filterHeader]?.first)
        }
    }

    /// The Phase-1 map-filter side channel: `QueryTileRequest` has no filter
    /// field on the wire, so the Maps repository sends the active pill as this
    /// request header. The values are `MapFilter.rawValue` strings from the
    /// Maps feature, matched literally here (this package can't import it);
    /// unknown or absent tokens fail open to "all".
    static let filterHeader = "x-map-filter"

    private func queryTile(
        _ request: GeoDiscovery_V1_QueryTileRequest,
        filter: String?
    ) -> Result<GeoDiscovery_V1_QueryTileResponse, ConnectError> {
        let viewport = request.viewport
        var response = GeoDiscovery_V1_QueryTileResponse()

        let pins = dataset.posts.enumerated().compactMap { index, post -> GeoDiscovery_V1_RadarPin? in
            // A venue's members share ONE coordinate exactly, so they cluster
            // at every zoom; everything else keeps its own scattered point.
            let (lat, lng) = venues[post.postID].map { ($0.lat, $0.lng) }
                ?? Self.coordinate(forIndex: index)
            guard Self.contains(viewport: viewport, lat: lat, lng: lng),
                  matches(filter: filter, post: post, lat: lat, lng: lng, viewport: viewport)
            else { return nil }

            var pin = GeoDiscovery_V1_RadarPin()
            pin.postID = post.postID
            pin.lat = lat
            pin.lng = lng
            // A text-only post is indexed like any other, with an EMPTY
            // thumbnail — the only way the wire can say "no cover" (`RadarPin`
            // has no media kind). The client reads that as `MapPin.Kind.text`
            // and gives the marker a symbol face.
            pin.thumbnailURL = post.media.map {
                Self.pinURL(forMediaURL: $0.url, catalog: dataset.mediaCatalog)
            } ?? ""
            return pin
        }

        response.pins = Array(pins.prefix(Self.topK))
        // Stand-in tile count: scales with how wide the viewport is.
        response.tileCount = Int32(max(1, pins.count / 12 + 1))
        return .success(response)
    }

    /// One `MapFilter` bucket, resolved against the shared dataset:
    /// - `friends` / `following`: author-set intersection (the backend's
    ///   documented client-side design, playable here because the mock knows
    ///   authorship even though `RadarPin` carries no `author_id`).
    /// - `pinned`: the dataset's seeded saved-places set.
    /// - `nearby`: a tight radius around the viewport center (the mock has no
    ///   user location; the center is the stand-in).
    /// - `profile:<id>`: that profile's posts only (the bar's favorites).
    private func matches(
        filter: String?,
        post: MockSocialDataset.PostRecord,
        lat: Double,
        lng: Double,
        viewport: GeoDiscovery_V1_Viewport
    ) -> Bool {
        // Multi-selection (the sub-filter row's multi-select) arrives as its
        // leaf tokens joined by commas, with OR semantics: a pin matching any
        // member is shown.
        if let filter, filter.contains(",") {
            return filter.split(separator: ",").contains { member in
                matches(
                    filter: String(member), post: post, lat: lat, lng: lng, viewport: viewport
                )
            }
        }
        switch filter {
        case "friends":
            return dataset.mutualProfileIDs.contains(post.authorProfileID)
        case "following":
            return dataset.followedProfileIDs.contains(post.authorProfileID)
        case "pinned":
            return dataset.pinnedPostIDs.contains(post.postID)
        case "nearby":
            let centerLat = (viewport.swLat + viewport.neLat) / 2
            let centerLng = (viewport.swLng + viewport.neLng) / 2
            let dLat = lat - centerLat
            let dLng = lng - centerLng
            return dLat * dLat + dLng * dLng <= Self.nearbyRadius * Self.nearbyRadius
        default:
            if let filter, filter.hasPrefix("profile:") {
                return post.authorProfileID == String(filter.dropFirst("profile:".count))
            }
            if let filter, filter.hasPrefix("pinned:") {
                // Places narrowed to one category (the sub-filter row).
                let category = String(filter.dropFirst("pinned:".count))
                return dataset.pinnedPlaceCategories[post.postID] == category
            }
            return true // no/unknown filter → fail open, show everything
        }
    }

    /// "Nearby" cutoff in degrees (~4 km) — well inside the ±0.15° scatter,
    /// so selecting the pill visibly thins the field at the default zoom.
    private static let nearbyRadius = 0.04

    /// Mirrors the Maps feature's semantic-clusters launch argument (read
    /// here the same way `-maps-force-video` is): with it, a deterministic
    /// THIRD of the non-venue corpus is seeded across European anchors —
    /// cities, regions and countries beyond Paris — so the H3 hierarchy has
    /// several distinct entities per level to band, at every geographic
    /// scale. Without the flag the scatter is exactly the historical
    /// Paris-only fixture.
    static let spreadsHierarchy =
        ProcessInfo.processInfo.arguments.contains("-maps-mock-semantic-clusters")

    /// The European anchors the spread rotates over, matching the zone
    /// ladders in the Maps feature's `MapMockPlaces` (the spec's mock-parity
    /// contract ties the two files): three cities, two region scatters, two
    /// country scatters.
    static let hierarchyAnchors: [(lat: Double, lng: Double, jitter: Double)] = [
        (45.7640, 4.8357, 0.10),  // Lyon (city)
        (43.2965, 5.3698, 0.10),  // Marseille (city)
        (43.9000, 6.2000, 0.30),  // Provence scatter (region)
        (41.3874, 2.1686, 0.10),  // Barcelona (city)
        (41.9000, 1.6000, 0.30),  // Catalonia scatter (region)
        (40.4200, -3.7000, 0.30), // Madrid area (Spain, country)
        (52.5200, 13.4050, 0.30), // Berlin area (Germany, country)
    ]

    /// Deterministic scatter: two coprime strides over the index fan posts out
    /// across the box without randomness, so runs are reproducible. Under the
    /// hierarchy flag, every third post is re-anchored across Europe instead —
    /// same strides, so which posts travel never changes between runs.
    private static func coordinate(forIndex index: Int) -> (lat: Double, lng: Double) {
        let latFraction = Double((index * 73) % 1000) / 1000.0
        let lngFraction = Double((index * 137) % 1000) / 1000.0
        if spreadsHierarchy, index % 3 == 2 {
            let anchor = hierarchyAnchors[(index / 3) % hierarchyAnchors.count]
            return (
                anchor.lat + (latFraction * 2 - 1) * anchor.jitter,
                anchor.lng + (lngFraction * 2 - 1) * anchor.jitter
            )
        }
        let lat = baseLat + (latFraction * 2 - 1) * spread
        let lng = baseLng + (lngFraction * 2 - 1) * spread
        return (lat, lng)
    }

    private static func contains(viewport: GeoDiscovery_V1_Viewport, lat: Double, lng: Double) -> Bool {
        lat >= viewport.swLat && lat <= viewport.neLat
            && lng >= viewport.swLng && lng <= viewport.neLng
    }
}
