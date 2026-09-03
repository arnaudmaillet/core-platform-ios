# Backend: author identity on `RadarPin` — avatar (and id) for map markers

**Service:** `geo_discovery.v1` · **Status:** proposal — the fields exist on the
wire, but on the wrong message
**Client:** iOS Maps tab (every marker, at every zoom, on every pan)
**Related:** `dev/BACKEND_GAPS.md` §15 (`RadarPin` renditions), §18 (semantic
clusters), `dev/issues/BACKEND_CLUSTER_TYPES.md`

## Summary

A text-only post has no cover, so its marker cannot be a photograph. It is a
glyph today, which makes the map's text posts anonymous: a field of
photographs punctuated by identical symbols. The product wants the **author's
avatar** there instead — the marker still reads as "not a photo", but it says
*whose* it is.

The client cannot draw it. `RadarPin` is `post_id / lat / lng / thumbnail_url`
and carries no author at all.

## What already exists, and why it does not answer

`geo_discovery.v1` HAS the field — on `MapPostCard`:

    post_id, author_id, author_handle, author_avatar_url, thumbnail_url, h3_cell

but `MapPostCard` is returned only by **`GetGeoTimeline`**, whose own contract
note is explicit about the split:

> Targeted enrichment for one or more pins the user has focused. Batched so a
> bottom-sheet can expand a cluster in a single round-trip. Reads the hydrated
> card from Redis, falling back to ScyllaDB on cache miss — the cold-read path
> that the Radar pan path deliberately avoids.

and `QueryTileResponse.pins`:

> Lightweight pins only. Radar/Focus split: the pan path returns markers, not
> hydrated cards. Clients hydrate on tap via GetGeoTimeline.

So the avatar is reachable **after a tap**, and what is needed is the avatar
**before** one — for every text marker in the viewport, on every pan. Calling
`GetGeoTimeline` for them is exactly the cold read the design excludes, and at
country zoom the text pins in a viewport are not a bottom-sheet's worth.

## Ask

Two additive fields on `RadarPin`:

| field | why |
|---|---|
| `string author_avatar_url` (field 5) | the marker face for a text post |
| `string author_id` (field 6) | see below — three features are waiting on it |

`author_avatar_url` may be a small square rendition; the marker draws it at
~44pt, so a 128px variant is ample and keeps the Radar payload light. Empty
string is a legitimate answer (author has no avatar) and the client falls back
to the glyph it draws today.

### `author_id` is not scope creep

Three client behaviours already documented as blocked name this same missing
field:

- **Filtering the map by friends / following.** `MapFilter` resolves those sets
  client-side by intersecting author ids — the backend's own documented design
  for `MapPostCard` badges ("clients resolve these locally by intersecting
  author_id with their session-cached social graph sets"). The map cannot,
  because the pan path has no author. Today it works in mock mode only.
- **Muting.** `MapsViewController` records that a muted author cannot be
  filtered out of the map for the same reason.
- **Avatar grouping for clusters.** A cluster of text posts by one author
  should wear that author once; with no id the client cannot tell.

Shipping `author_avatar_url` alone would light up the marker and leave the
other two blocked on a second round.

## Payload cost

`RadarPin` is Top-K capped per H3 tile. Adding a URL and an id to each pin is
roughly +80 bytes per marker; at a 200-pin viewport that is ~16 KB, against a
`thumbnail_url` already carried on every media pin. If that is judged too much
for the pan path, an acceptable narrower version is **`author_avatar_url` only
on pins whose `thumbnail_url` is empty** — the text pins are the only ones that
need it, and they are the minority.

## Until it ships

iOS carries `MapPin.authorAvatarURL`, `nil` in production, populated in DEBUG
mock mode by the same decorator pattern `MapPlace` uses (`MapMockPlaces`). The
marker draws the avatar when it has one and the glyph when it does not, so the
production build is unchanged and the day the field lands the client needs only
to map it in `GeoDiscoveryRepository`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
