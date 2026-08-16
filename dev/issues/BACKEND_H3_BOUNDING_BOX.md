# Backend: H3-backed cluster bounds and viewport-driven resolution

**Service:** `geo_discovery.v1` · **Status:** aligned architecture (supersedes the
zoom-band half of `BACKEND_CLUSTER_TYPES.md`; the `GeoCluster`/`QueryClusterPosts`
shapes there still stand)
**Client:** iOS Maps tab — hierarchical clusters, dynamic banding, camera fits
**Related:** `dev/BACKEND_GAPS.md` §18 · `dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §C

## Summary

Semantic clusters (city/region/country) stop being described by hand-tuned zoom
thresholds and become **H3-backed**: every cluster (and, additively, every pin)
carries an `h3_index`, and an H3 index unambiguously determines a deterministic
geographic cell — its resolution, its center, its boundary polygon, and
therefore its bounding box. The client derives the cluster's span from the
cell and compares it to the live camera viewport to decide which hierarchy
level renders, when a parent opens into its children, and what region a
camera fit should target — no fixed zoom table on either side of the wire.

## Proto additions (all additive)

### A. `RadarPin.h3_index`

```proto
message RadarPin {
  // ... post_id = 1, lat = 2, lng = 3, thumbnail_url = 4 unchanged ...
  // ⚠️ field 5 is RESERVED for media_kind, already proposed in
  // BACKEND_MEDIA_PREVIEW_RENDITIONS.md §C. Two in-flight additive
  // proposals must not share a number:
  int64 h3_index = 6;  // the H3 cell (mode-1 index) this pin was bucketed
                       // into at index time, at the SERVER'S chosen
                       // resolution for the query (see resolution logic
                       // below); 0 = not indexed
}
```

> **Field-number note:** the request that produced this spec asked for
> `h3_index = 5`. Field 5 of `RadarPin` is already assigned to
> `media.v1.MediaKind media_kind` by the renditions proposal, which predates
> this one and is referenced from shipped client comments
> (`GeoDiscoveryRepository.kind(for:)`). This spec therefore takes **6** and
> flags the collision so the two proposals land compatibly.

### B. `GeoCluster.h3_index`

The `GeoCluster` message proposed in `BACKEND_CLUSTER_TYPES.md` gains the same
field (and may drop its speculative `Viewport bounds = 9`, which the H3 cell
now answers deterministically):

```proto
message GeoCluster {
  // ... cluster_id, kind, name, lat, lng, member_count, representative,
  //     top_post_ids unchanged ...
  int64 h3_index = 10;  // the cell this cluster aggregates over; its
                        // boundary IS the cluster's bounding box
}
```

## Server-side resolution logic

`crates/services/geo-discovery` currently bands `QueryTileRequest.zoom_level`
(0–15, client-derived from the longitude span) onto H3 resolutions via a fixed
`zoom_to_resolution` table. Replace the input, keep the shape:

1. Derive the viewport's **diagonal in km** from the `Viewport` corners already
   on the request (`sw`/`ne`; no new field needed — haversine or the flat
   approximation is fine at these scales).
2. Choose the aggregation resolution as the finest H3 resolution whose average
   cell span (2 × average hex edge length) is ≥ `diagonal_km × fit_ratio`,
   with `fit_ratio ≈ 0.5` (tunable; the client mirrors this rule for
   rendering, see below). Clamp to the service's supported range.
3. `zoom_level` stays on the wire for compatibility and telemetry, but no
   longer selects the resolution; requests from old clients (which always send
   it) band identically because the server derives the diagonal from the same
   viewport they already send.

This makes the resolution ladder continuous with the camera rather than
stepped by the client's log2 span bucketing, and it is what lets the client
drop its own zoom tables.

## Client contract (what iOS ships against this)

- `h3_index` is treated as a mode-1 (cell) H3 index; anything else is ignored
  (logged in DEBUG). The client reads the RESOLUTION bits to derive the cell's
  average span from the published per-resolution edge-length table, and uses
  the pin/cluster's own `lat`/`lng` as the cell anchor. Exact hexagon
  boundaries (full H3 cell-to-boundary math) are not required for banding or
  camera fits; if survey-exact outlines become a product need, the client
  vendors the H3 kernel then — the wire shape does not change.
- **Dynamic banding rule** (mirrors the server's): with `spanKm(level)` the
  H3-derived span of each hierarchy level present in the corpus and
  `diagKm` the camera viewport's diagonal —
  - if the DEEPEST level's `spanKm / diagKm > local_ratio (≈1.6)`, the viewer
    is inside that cell: render individual posts / local proximity clusters;
  - else render the deepest level with `spanKm / diagKm ≥ fit_ratio (≈0.75)`;
  - else (zoomed out past everything) render the coarsest level.
  One level renders at a time (the strict-banding contract in PR #117);
  fixed zoom thresholds remain only as the fallback when no `h3_index` is
  present anywhere in the corpus.
- Vocabulary: the client speaks the official `geo_discovery.v1` names on the
  wire (`RadarPin`, `MapPostCard`, `Viewport`); `MapPlace` remains the
  client-side projection of the (still-proposed) `GeoCluster` identity and is
  renamed when that message ships.

## Acceptance criteria

1. `QueryTile` responses over a seeded corpus stamp every pin with a mode-1
   `h3_index` whose resolution matches the viewport-diagonal rule above
   (verifiable: halving the viewport diagonal moves the resolution finer by
   one within the supported range).
2. A pin's `lat`/`lng` falls inside the cell its `h3_index` names.
3. `zoom_level` no longer changes the chosen resolution when the viewport is
   held constant.
4. Old clients (ignoring field 6) round-trip unchanged; `media_kind = 5`
   remains available to the renditions proposal.

## Open questions

1. Does the fleet's geo store already keep per-post H3 at multiple
   resolutions (r7 exists on `MapPostCard.h3_index_r7`), or is re-indexing
   required for coarse resolutions?
2. Should `fit_ratio` ship as a server-tunable (config) with the client
   simply consuming whatever resolution arrives? (Client preference: yes —
   the client rule above then only governs its own mock era.)
