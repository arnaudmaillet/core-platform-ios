# Backend: semantic geo clusters (city / country / region) for the map

**Service:** `geo_discovery.v1` · **Status:** proposal — nothing on the wire today
**Client:** iOS Maps tab (pin/cluster tap → feed → cluster gallery)
**Related:** `dev/BACKEND_GAPS.md` §14 (no ranking RPC), §15 (`RadarPin` renditions),
`dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §C

## Summary

The map is growing a second kind of cluster. Today every cluster the user sees
is **client-side screen-space proximity**: the client fetches raw `RadarPin`s
for the viewport and merges markers that would collide at the current zoom.
That stays. What the product now needs on top is the **semantic cluster** — "the
posts of Paris", "the posts of France" — which behaves differently on tap: it
opens a full-screen post viewer with a **gallery of the place's popular posts**
behind it, titled with the place's name, and the viewer dismisses into that
gallery instead of back to a lone pin.

The client cannot derive any of that from the current contract. `RadarPin` is
`post_id / lat / lng / thumbnail_url` — no place identity, no name, no grouping
key — and `QueryTile` is Top-K-capped per H3 tile, so at country zoom the client
never even receives the majority of the posts it would need to group. Semantic
clustering is aggregation over the whole corpus at a geographic level; it has to
happen server-side, exactly like the existing per-tile Top-K already does.

Until this ships, iOS simulates semantic clusters in DEBUG builds with a
client-side place catalog over the mock dataset (`-maps-mock-semantic-clusters`),
so the entire navigation surface is built and testable today. The launch arg and
catalog are deleted the day the fields below land.

## Problem

1. **No place identity.** Nothing in `geo_discovery.v1` says two pins belong to
   the same city/country/region. The client's proximity merge is a rendering
   optimization, not a statement about geography — two pins 200 m apart merge at
   one zoom and split at the next.
2. **No place names.** The gallery is titled "Paris • City Cluster". No RPC
   returns a display name for any geographic grouping (there is no reverse
   geocoding anywhere in the contracts).
3. **Top-K starves aggregation.** `QueryTileResponse` caps pins per tile
   (mock: 80). At country zoom the viewport spans many tiles and the response is
   a sample. Client-side counting over a sample cannot say "France, 12,438
   posts" — only the server can.
4. **No ranking for the gallery.** The gallery shows the place's
   *popular/trending* posts. §14 already records that no discovery/ranking RPC
   exists; `MapPostCard.virality_score` proves the signal exists server-side,
   but there is no way to ask "top posts of this place".

## Current contract reality

- `QueryTileRequest`: `viewport` (1), `zoom_level` (2 — the client's 0–15 band,
  already sent, already used for H3 banding server-side).
- `QueryTileResponse`: `tile_count` (2), `pins` (3), `cards` (11).
- `RadarPin`: `post_id` (1), `lat` (2), `lng` (3), `thumbnail_url` (4) —
  field 5 (`media_kind`) is spec'd in the renditions issue but unpublished.
- `GetGeoTimeline(post_ids) → cards`: hydration by explicit id list; no place
  parameter, no cursor.

## Proposal (all additive; no renumbering, no breaking change)

### A. `ClusterKind` enum

```proto
enum ClusterKind {
  CLUSTER_KIND_UNSPECIFIED = 0;
  CLUSTER_KIND_CITY        = 1;
  CLUSTER_KIND_COUNTRY     = 2;
  CLUSTER_KIND_REGION      = 3;  // sub-national: state / département / prefecture
  CLUSTER_KIND_GENERIC     = 4;  // dense non-place group the server chose to
                                 // pre-aggregate; client treats it exactly like
                                 // its own proximity clusters (no gallery)
}
```

The client's behavioral split is: `CITY | COUNTRY | REGION` → gallery-backed
viewer; `GENERIC` (and every client-side proximity merge) → plain viewer that
dismisses to the pin. `GENERIC` exists so the server may *also* pre-aggregate
hotspots without promising place semantics; it must never carry a made-up name.

### B. `GeoCluster` message

```proto
message GeoCluster {
  string      cluster_id     = 1;  // stable across queries; e.g. "city:fr-paris",
                                   // "country:fr". The client keys marker identity,
                                   // dedupe and navigation state on it.
  ClusterKind kind           = 2;
  string      name           = 3;  // display name, e.g. "Paris", "France".
                                   // REQUIRED for city/country/region; the client
                                   // titles the gallery "<name> • <kind> Cluster".
  double      lat            = 4;  // marker anchor (centroid or civic center)
  double      lng            = 5;
  int64       member_count   = 6;  // total posts in the place, NOT capped —
                                   // this is the number the client can't compute
  RadarPin    representative = 7;  // the marker's face: the MOST POPULAR
                                   // member (engagement desc — the same rule
                                   // that ranks top_post_ids, so the face is
                                   // top_post_ids[0]); same contract as a pin
                                   // (empty thumbnail_url = text face)
  repeated string top_post_ids = 8; // popular members, ranked (virality desc),
                                    // capped ~60; seeds the gallery's first
                                    // screen + the viewer; hydrate via
                                    // GetGeoTimeline / QueryClusterPosts
  Viewport    bounds         = 9;  // optional: the place's bounding box, for
                                   // camera fit on secondary actions
}
```

### C. `QueryTileResponse.clusters`

```proto
message QueryTileResponse {
  // ... tile_count = 2, pins = 3, cards = 11 unchanged ...
  repeated GeoCluster clusters = 12;
}
```

Banding rule (server-side, driven by the `zoom_level` already in the request —
thresholds are the server's to tune, these are the client's assumptions):

| `zoom_level` band | response contains |
|---|---|
| 0–3 (world/continent) | `COUNTRY` clusters + residual pins |
| 4–7 (country/region)  | `REGION`/`CITY` clusters + residual pins |
| 8–15 (city/street)    | pins only (today's behavior), clusters optional for dense POIs |

Invariants the client relies on:
- **A post is in a cluster or a pin, never both** in one response — a pin
  absorbed by a returned cluster must not also appear in `pins`. (The client
  still runs proximity merging over whatever `pins` remain.)
- `clusters` is empty at high zoom → responses are byte-compatible with today's;
  old clients ignore field 12 entirely (proto3 unknown-field rules).
- `member_count >= len(top_post_ids) >= 1`; `representative.post_id` is always
  one of the member posts.

### D. `QueryClusterPosts` RPC (gallery body + pagination)

```proto
rpc QueryClusterPosts(QueryClusterPostsRequest) returns (QueryClusterPostsResponse);

message QueryClusterPostsRequest {
  string cluster_id = 1;
  ClusterOrder order = 2;   // TRENDING (virality desc) | RECENT (published_at desc)
  string page_token = 3;
  int32  page_size  = 4;    // server-capped (suggest 30)
}
message QueryClusterPostsResponse {
  repeated MapPostCard cards = 1;  // reuse the existing hydrated card
  string next_page_token     = 2;
}
```

`top_post_ids` + `GetGeoTimeline` covers the first gallery screen with zero new
RPCs; `QueryClusterPosts` is what makes the gallery scroll past it. If only one
of C/D can ship first, ship C — the client degrades to a 60-post gallery.

## Client contract (what iOS guarantees)

- `cluster_id` is treated as opaque; no parsing, no locale assumptions.
- The client renders `name` verbatim (server localizes or doesn't; see open
  questions) and falls back to a nameless generic marker if `name` is empty on
  a semantic kind (defensive; also logged as a data bug).
- Tapping a semantic cluster opens the viewer seeded from `top_post_ids`
  (representative first if present in the list, else server order) with the
  gallery behind it; `GENERIC` clusters and proximity merges keep today's
  seeded-feed behavior.
- Unknown `ClusterKind` values (future additions) degrade to `GENERIC`
  behavior, never to a gallery with an unlabeled type.

## Mock parity (what the fixture must reproduce once fields exist)

`MockGeoDiscoveryService` should mirror the banding rule over the seeded corpus:
below the city band return one `CITY` cluster per venue (venues already share an
exact coordinate), one `REGION` over the Paris scatter, one `COUNTRY` over
everything — `member_count` from the true seed counts, `top_post_ids` ranked by
the seeded like counters. Until then the DEBUG place catalog fakes the same
shapes client-side; both are keyed off the same venue coordinates so the switch
is a deletion, not a rewrite.

## Acceptance criteria

1. `QueryTile` at `zoom_level <= 3` over a seeded corpus returns ≥1 `COUNTRY`
   cluster whose `member_count` equals the true corpus count for that country,
   with no member post duplicated in `pins`.
2. `QueryTile` at `zoom_level 8+` over the same viewport returns exactly today's
   pin payload (`clusters` empty).
3. Every semantic cluster carries a non-empty `name` and a `representative`
   whose `post_id` ∈ members.
4. `QueryClusterPosts(cluster_id, TRENDING)` pages the full membership,
   `next_page_token` empty on the last page, stable order across pages.
5. A client that has never seen field 12 round-trips `QueryTileResponse`
   unchanged (additive-only check).

## Open questions

1. **Localization of `name`** — server-localized via `Accept-Language`, or a
   canonical (English/endonym) name the client renders as-is? iOS is fine with
   either; it will not translate.
2. **Region granularity** — what is a `REGION` outside FR/US administrative
   models? The client only displays it; the taxonomy is the server's.
3. **Cluster ↔ filter interaction** — does the `x-map-filter` header (and its
   future proto field) narrow `member_count`/`top_post_ids`, or are semantic
   clusters filter-blind? Client preference: filtered, so the marker never
   advertises posts the current pill would hide.
4. **Should `bounds` (field 9) ship in v1?** The client's only near-term use is
   camera fit; droppable if it complicates aggregation.

## References

- `Packages/Features/Maps/Sources/Maps/Model/MapClusterEngine.swift` — the
  client-side proximity engine that keeps running over residual pins.
- `Packages/Features/Maps/Sources/Maps/Data/GeoDiscoveryRepository.swift` —
  the decode seam where `clusters` will be projected.
- `Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/MockGeoDiscoveryService.swift`
  — venues + Top-K fixture this spec's mock parity section refers to.
- `dev/BACKEND_GAPS.md` §14, §15 — the ranking and rendition gaps this
  proposal intersects.
