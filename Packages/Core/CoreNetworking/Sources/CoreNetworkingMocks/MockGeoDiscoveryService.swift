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
    /// Whether a deterministic THIRD of the non-venue corpus is re-anchored
    /// across `hierarchyAnchors` — the European seed the semantic-cluster
    /// surface stands on. INJECTED by the composition root, not read from
    /// ProcessInfo here: the app defaults it ON in mock mode (opt out with
    /// `-maps-mock-no-places`), while tests constructing this service
    /// directly keep the historical Paris-only scatter their fixtures are
    /// calibrated against.
    private let spreadsHierarchy: Bool

    /// Central Paris — the map's default region centers here.
    private static let baseLat = 48.8566
    private static let baseLng = 2.3522
    /// Scatter radius in degrees (~±16 km), enough to exercise pan and clustering.
    private static let spread = 0.15
    /// Per-response cap, standing in for the server's per-tile Top-K. Loose
    /// on purpose: the real service caps per TILE, so a wide viewport's
    /// response spans many tiles and grows with them — a tight per-response
    /// number here would silently hide the tail of a corpus enlarged via
    /// `-mock-post-count` (the prefix is dataset-ordered, so everything past
    /// it would simply never reach the map).
    private static let topK = 200

    public init(dataset: MockSocialDataset, spreadsHierarchy: Bool = false) {
        self.dataset = dataset
        self.spreadsHierarchy = spreadsHierarchy
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
        // ⚠️ TEXT MEMBERS COME FROM THE CORPUS BODY, NEVER FROM THE ARRIVALS —
        // and that is what keeps the mixed venue wearing a text face.
        //
        // A marker's face is its most-liked member, but the Radar path hydrates
        // counters only when the caller passes a counter client: without one
        // every pin arrives at likeCount 0 and the choice falls through to the
        // members' id order (`MapClusterEngine.representative` keeps the first
        // on ties). `post-00xx` sorts before `post-new-xx`, so the mixed venue's
        // face was a text post for exactly one reason — one text post from the
        // corpus body sat in it while all its media came from the arrivals.
        //
        // The arrivals are a FEED fixture. It gained a second text post (an
        // adjacent text pair the snap pager needs), the venue walk took both,
        // no `post-00xx` text member was left, and the mixed marker turned
        // media-faced — failing `aTextFacedMixedClusterOpensBothKinds`, in a
        // package that had not been touched. Drawing text from the body pins
        // the property to something the Feed cannot move.
        var text = posts.lazy
            .filter { $0.media == nil && !$0.postID.hasPrefix(MockSocialDataset.arrivalIDPrefix) }
            .map(\.postID).makeIterator()
        // ⚠️ VIDEO AND PHOTO DRAW FROM SEPARATE ITERATORS.
        //
        // One `media` iterator cannot be asked for a balance it does not know
        // about: it walks the corpus in order and hands back whatever comes
        // next. The venues are what the default viewport mostly SHOWS — the
        // scatter contributes a handful — so an assignment that counts "media"
        // decides the map's whole composition by accident. Measured before this,
        // in the default viewport: photo 7, text 8, video 3, from a corpus that
        // is an exact 40/40/40.
        var video = posts.lazy
            .filter { $0.media.map { MockMediaFixtures.isVideoURL($0.url) } ?? false }
            .map(\.postID).makeIterator()
        var photo = posts.lazy
            .filter { $0.media.map { !MockMediaFixtures.isVideoURL($0.url) } ?? false }
            .map(\.postID).makeIterator()
        func assign(_ venue: Venue, text textCount: Int, video videoCount: Int, photo photoCount: Int) {
            for _ in 0..<textCount { if let id = text.next() { assignments[id] = venue } }
            for _ in 0..<videoCount { if let id = video.next() { assignments[id] = venue } }
            for _ in 0..<photoCount { if let id = photo.next() { assignments[id] = venue } }
        }
        // ⚠️ These counts are load-bearing beyond clustering: which posts land
        // here decides each venue's MOST-LIKED member, and that is the face the
        // app draws. `aTextFacedMixedClusterOpensBothKinds` rests on the
        // arithmetic too, but on the OTHER half of it: that suite builds its
        // repository without a counter client, so its pins are all at likeCount
        // 0 and the id order decides instead — see the note on the text walk. The PLACE PROFILE's three tabs don't need more members
        // at venue scale: the mixed venue already spans all three kinds, and
        // the city/region markers roll up the whole zone's corpus.
        // Even thirds, venue by venue, so the map shows what the corpus is.
        // The mixed venue still spans all three kinds — the property
        // `aTextFacedMixedClusterOpensBothKinds` rests on — and the media-only
        // venue still holds no text.
        // ⚠️ RAISED, and evenly. The venues are what the default viewport mostly
        // holds — the scatter contributes a handful — so their quota IS the
        // map's composition. At 2/2/2 they were a minority of the pins and the
        // scatter's draw decided the balance; at 8/8/8 they dominate it, and the
        // scatter becomes a perturbation rather than the answer.
        //
        // The venues keep their meanings: the text-only one takes only text, the
        // media-only one takes no text, and the mixed one spans all three —
        // which `aTextFacedMixedClusterOpensBothKinds` rests on.
        assign(mixedVenue, text: 4, video: 4, photo: 4)
        assign(textOnlyVenue, text: 4, video: 0, photo: 0)
        assign(mediaOnlyVenue, text: 0, video: 4, photo: 4)
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
        guard catalog == .realAssets else { return url }
        // ⚠️ Under the FORCE flag, every covered pin becomes a video pin.
        //
        // It used to force only posts whose media was already a video, which is
        // one third of the corpus — and after clustering, none of those survived
        // as a LONE pin in the default viewport, so the playback path had
        // literally never run. A flag named `-maps-force-video` that produces
        // zero playing videos is a flag that measures nothing.
        //
        // Outside the flag the old rule stands: a real video post gets a still,
        // because handing the raw video URL to an image view renders a blank pin.
        guard MockMediaFixtures.isVideoURL(url) || forcesMapVideo else { return url }
        guard forcesMapVideo else {
            // A still, because handing a raw video URL to an image view renders
            // a blank pin — but STAMPED, so the pin can say what its post is.
            //
            // ⚠️ Without the stamp the map has no video pins at all. `RadarPin`
            // carries no media kind (`media.v1.MediaKind media_kind = 5` is not
            // published to BSR, `dev/BACKEND_GAPS.md` §15), so every media pin
            // classified as `.photo` and the corpus's honest thirds — 40 video,
            // 40 photo, 40 text — reached the map as two thirds photo and no
            // video whatsoever. The play badge and the preview path could only
            // ever be seen under `-maps-force-video`, which makes EVERY pin a
            // video and is therefore no better a picture of the product.
            //
            // A query item the origin ignores, mirroring the discriminator
            // below. It is a mock standing in for field 5, and it disappears the
            // day field 5 ships.
            let still = MockMediaFixtures.imageURL(index: url.count, width: 256, height: 256)
            return "\(still)?\(Self.videoKindMarker)"
        }
        // ⚠️ ONE FIXTURE, DISTINCT URLS — and the distinctness is the fixture's
        // whole job now.
        //
        // Every video pin used to get the identical `mapPreviewLoop` url. The
        // pool shares one player when the asset AND the scope match, the map
        // passed no scope, so `nil == nil` and three markers joined ONE player:
        // three surfaces drawing one decoder on one clock. Any reading of
        // "three concurrent videos" taken against that fixture was a reading of
        // one video, and the cap it justified was never exercised.
        //
        // The discriminator is a query item the origin ignores (verified 206),
        // so this is the SAME 320x176 clip decoded N times — which is what a
        // concurrency test needs. Rotating real files instead would vary
        // resolution and bitrate and measure those rather than concurrency.
        let discriminator = url.reduce(into: UInt64(5381)) { $0 = $0 &* 33 &+ UInt64($1.asciiValue ?? 0) }
        return "\(MockMediaFixtures.mapPreviewLoop.url)&pin=\(discriminator % 9973)"
    }

    /// Mirrors the Maps feature's own DEBUG launch argument. Read here so the
    /// fixture a pin carries matches how the client will classify it.
    static let forcesMapVideo = ProcessInfo.processInfo.arguments.contains("-maps-force-video")

    /// The mock's stand-in for `media.v1.MediaKind`, read by
    /// `GeoDiscoveryRepository.kind(for:)` in DEBUG builds only.
    public static let videoKindMarker = "mock-kind=video"

    /// `-maps-mock-density <n>`: emit `n` copies of every matching post,
    /// scattered across the queried viewport.
    ///
    /// The corpus is ~100 posts spread over Paris, so a viewport holds five to
    /// thirteen markers — enough to prove a feature works and nowhere near
    /// enough to prove it scales. The map's real worst case is a SATURATED
    /// marker lattice: `MapClusterEngine` keeps markers 64pt apart, so a
    /// 440x956pt screen tops out at 8 x 16 = 128, and in any populated city
    /// that is the ordinary count rather than a rare peak.
    ///
    /// Replication rather than more fixtures: the point is marker COUNT under
    /// pan and zoom, and inventing a hundred more posts would drag every other
    /// mock surface — like counts, venues, arrivals — along with it. Position
    /// is derived from the post id and the copy index, so a run is
    /// reproducible.
    /// `-maps-mock-pitch <points>` — see `replicated`.
    static let pitchOverride: Double? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-maps-mock-pitch"),
              index + 1 < arguments.count, let value = Double(arguments[index + 1])
        else { return nil }
        // ⚠️ Floor of 16, not 64. The 64 was a guard against laying pins
        // closer than the cluster engine's merge threshold — sensible while
        // clustering was on, and exactly wrong once `-maps-no-clustering`
        // exists, because then a tighter pitch is the ONLY way to stand a
        // 128-marker field in front of the renderer. Clamping silently made
        // `-maps-mock-pitch 45` and `-maps-mock-pitch 32` identical to 64, and
        // the marker count did not move across three runs.
        return max(16, value)
    }()

    static let density: Int = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-maps-mock-density"),
              index + 1 < arguments.count, let value = Int(arguments[index + 1])
        else { return 1 }
        return max(1, min(value, 40))
    }()

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
                ?? coordinate(forIndex: index, postID: post.postID)
            guard Self.contains(viewport: viewport, lat: lat, lng: lng),
                  matches(filter: filter, post: post, lat: lat, lng: lng, viewport: viewport)
            else { return nil }

            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-maps-log-pins") {
                let kind = post.media.map {
                    MockMediaFixtures.isVideoURL($0.url) ? "video" : "photo"
                } ?? "text"
                print("[pins] \(post.postID) \(kind) "
                      + "\(venues[post.postID] != nil ? "venue" : "scatter")")
            }
            #endif
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

        // ⚠️ The Top-K cap is lifted for the density fixture. It is 200 by
        // default, and a saturated lattice is allowed to exceed that — capping
        // it here would silently thin the very field the flag exists to build.
        let replicated = Self.replicated(pins, across: viewport)
        response.pins = Array(replicated.prefix(Self.density > 1 ? replicated.count : Self.topK))
        // Stand-in tile count: scales with how wide the viewport is.
        response.tileCount = Int32(max(1, pins.count / 12 + 1))
        return .success(response)
    }

    /// Spreads `density` copies of each pin over the viewport.
    ///
    /// ⚠️ Each copy needs its OWN post id, or the client's diffing engine —
    /// which keys annotations by `postID` — collapses them all back into one
    /// marker and the density knob silently does nothing. The suffix keeps the
    /// original id as a prefix so `-maps-open-first-text-pin` and the icon seed
    /// still recognise it, and the ORIGINAL keeps its exact id so nothing that
    /// looks a post up by name breaks.
    private static func replicated(
        _ pins: [GeoDiscovery_V1_RadarPin], across viewport: GeoDiscovery_V1_Viewport
    ) -> [GeoDiscovery_V1_RadarPin] {
        guard density > 1, !pins.isEmpty else { return pins }
        let latSpan = abs(viewport.neLat - viewport.swLat)
        let lngSpan = abs(viewport.neLng - viewport.swLng)
        // ⚠️ SPACED AT THE CLUSTER PITCH, not packed as tightly as possible.
        //
        // Two wrong versions preceded this one, and both produced FEWER markers
        // by trying for more. `MapClusterEngine` merges anything closer than
        // 64pt, so clones dropped on a fine grid collapse right back into a
        // handful of clusters: a 15x15 lattice over a 440x956pt screen puts
        // markers 29pt apart and 200 pins came back as 13 markers.
        //
        // The saturated field IS the lattice — 440/64 ≈ 7 columns by 956/64 ≈ 15
        // rows, which is the 128-marker worst case this feature was designed
        // against. So the grid is derived from that pitch, in span fractions,
        // and `density` chooses how much of it to fill.
        // The lattice is derived from GEOMETRY, not guessed, and two guesses
        // preceded it — each producing FEWER markers than the last.
        //
        // The trap is that the queried viewport is not the visible screen.
        // `MKMapView.region` returns a region that CONTAINS the visible rect, so
        // on a tall phone it overshoots vertically — measured here at roughly
        // 2.8x the screen's height. A grid laid out as "one row per 64pt of
        // viewport" therefore puts most of its rows off-screen: 14 rows arrived
        // as five, spaced ~190pt apart, and the field looked sparse while the
        // arithmetic said it was saturated.
        //
        // So: convert the viewport to METRES, work out how many points it maps
        // to at the map's own fit, and space the grid at the cluster pitch in
        // those points. Everything off-screen is wasted rather than wrong.
        let metresPerDegree = 111_320.0
        let centreLat = (viewport.neLat + viewport.swLat) / 2
        let metresLat = latSpan * metresPerDegree
        let metresLng = lngSpan * metresPerDegree * cos(centreLat * .pi / 180)
        // The reference screen. A DEBUG fixture may know the device it is being
        // run on; production code may not, which is one more reason this lives
        // in the mock.
        let screen = (width: 440.0, height: 956.0)
        // The map fits the region to the view, so the binding axis is whichever
        // needs the smaller scale.
        let pointsPerMetre = min(screen.width / max(metresLng, 1), screen.height / max(metresLat, 1))
        // Just ABOVE the 64pt merge threshold by default: at exactly 64 the
        // engine is entitled to fold the pair, and one point under it certainly
        // does.
        //
        // ⚠️ `-maps-mock-pitch <points>` widens it, and the reason is not
        // cosmetic. At 70pt the engine's CHAINING merge still folds the field
        // into a handful of clusters — and a cluster never plays video, because
        // `MapVideoPlaybackCoordinator.Candidate.view` is typed
        // `MapAnnotationView`. So a video-playback experiment run at the default
        // pitch measures nothing: every video pin lands inside a cluster and the
        // path never runs. Widening the pitch is what produces LONE pins.
        let pitch = Self.pitchOverride ?? 70.0
        let columns = max(1, Int((metresLng * pointsPerMetre / pitch).rounded(.down)))
        let rows = max(1, Int((metresLat * pointsPerMetre / pitch).rounded(.down)))
        let slots = columns * rows
        let wanted = min(slots, max(1, density) * pins.count)

        return pins.enumerated().flatMap { pinIndex, pin -> [GeoDiscovery_V1_RadarPin] in
            let copies = wanted / pins.count + (pinIndex < wanted % pins.count ? 1 : 0)
            return (0..<max(1, copies)).map { copy in
                guard copy > 0 else { return pin }
                var clone = pin
                clone.postID = "\(pin.postID)#\(copy)"
                let slot = (pinIndex * (wanted / pins.count + 1) + copy) % slots
                let row = slot / columns, column = slot % columns
                clone.lat = viewport.swLat + latSpan * (Double(row) + 0.5) / Double(rows)
                clone.lng = viewport.swLng + lngSpan * (Double(column) + 0.5) / Double(columns)
                return clone
            }
        }
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

    // `spreadsHierarchy` (see the stored property above): when set, a
    // deterministic THIRD of the non-venue corpus is seeded across European
    // anchors — cities and countries beyond Paris — so the H3 hierarchy has
    // several distinct entities per level to band, at every geographic
    // scale. Unset, the scatter is exactly the historical Paris-only
    // fixture.

    /// The European anchors the spread rotates over, matching the zone
    /// ladders in the Maps feature's `MapMockPlaces` (the spec's mock-parity
    /// contract ties the two files): seven cities at tight jitter (0.10 —
    /// inside their 0.15° city circles, so every pin carries the city
    /// ladder) and three country-level countryside scatters (wide jitter,
    /// outside any circle → country-only ladders, hidden at the city band).
    /// Madrid and Berlin were promoted from countryside to cities on
    /// 2026-08-31 (with Rome and London added); the German countryside
    /// anchor keeps the country-only coverage Berlin's wide ring used to
    /// provide.
    static let hierarchyAnchors: [(lat: Double, lng: Double, jitter: Double)] = [
        (45.7640, 4.8357, 0.10),  // Lyon (city)
        (43.2965, 5.3698, 0.10),  // Marseille (city)
        (43.9000, 6.2000, 0.30),  // Provence countryside (France, country)
        (41.3874, 2.1686, 0.10),  // Barcelona (city)
        (41.9000, 1.6000, 0.30),  // Catalonia countryside (Spain, country)
        (40.4200, -3.7000, 0.10), // Madrid (city)
        (52.5200, 13.4050, 0.10), // Berlin (city)
        (51.0000, 9.5000, 0.40),  // Hesse countryside (Germany, country)
        (41.8933, 12.4829, 0.10), // Rome (city)
        (51.5074, -0.1278, 0.10), // London (city)
    ]

    /// Deterministic scatter: two coprime strides over the index fan posts out
    /// across the box without randomness, so runs are reproducible. Under the
    /// hierarchy flag, every third post is re-anchored across Europe instead —
    /// same strides, so which posts travel never changes between runs.
    private func coordinate(forIndex index: Int, postID: String) -> (lat: Double, lng: Double) {
        // ⚠️ SCATTERED BY THE POST'S ID, NOT BY ITS ARRAY INDEX.
        //
        // The kind is `index % 3` in this corpus, so a placement that is also a
        // function of `index` correlates position with kind, and the viewport
        // rectangle then samples the three classes unevenly — deterministically,
        // which is worse than noise because every launch shows the same skew.
        // Measured in the default viewport before this: photo 7, text 8, video 3
        // out of 18, from a corpus that is an exact 40/40/40.
        //
        // FNV-1a over the id, not `hashValue`: Swift seeds that per launch, and
        // a map whose pins move between runs is a fixture nobody can film twice.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in postID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        // ⚠️ FINALISE, then read the HIGH bits. FNV-1a's low bits barely move
        // for inputs that differ only in their last characters — and every id
        // here is `post-00NN`. Taking `hash % 1000` therefore kept the aliasing
        // with `index % 3` that switching away from the index was meant to
        // break: measured, the scatter placed FOUR photos and ZERO videos in the
        // default viewport, the same four every launch.
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        let latFraction = Double(hash >> 40) / 16777216.0
        let lngFraction = Double((hash >> 16) & 0xFF_FFFF) / 16777216.0
        if spreadsHierarchy, index % 3 == 2 {
            let anchor = Self.hierarchyAnchors[(index / 3) % Self.hierarchyAnchors.count]
            return (
                anchor.lat + (latFraction * 2 - 1) * anchor.jitter,
                anchor.lng + (lngFraction * 2 - 1) * anchor.jitter
            )
        }
        let lat = Self.baseLat + (latFraction * 2 - 1) * Self.spread
        let lng = Self.baseLng + (lngFraction * 2 - 1) * Self.spread
        return (lat, lng)
    }

    private static func contains(viewport: GeoDiscovery_V1_Viewport, lat: Double, lng: Double) -> Bool {
        lat >= viewport.swLat && lat <= viewport.neLat
            && lng >= viewport.swLng && lng <= viewport.neLng
    }
}
