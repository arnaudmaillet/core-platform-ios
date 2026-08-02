# Backend: distinct lightweight-preview vs full-stream media renditions

**Requested by:** iOS client team
**Area:** `media.v1`, `post.v1`, `geo_discovery.v1` (+ `search.v1`)
**Type:** Contract addition (all additive) + pipeline work
**Related:** `dev/PHASE3_VIDEO_BACKEND.md` (video pipeline — this extends §1),
`BACKEND_MEDIA_ASPECT_RATIO_SUPPORT.md` (same lightweight-path blind spot),
`dev/BACKEND_GAPS.md` §15.

## Summary

Two client surfaces render moving media, and they need **different** things from
the media pipeline. This is the central point of this issue — a single "video
URL" does not serve both:

| | **Map pins** (Radar/Focus) | **Gallery grid** (For You / Profile) |
|---|---|---|
| Concurrent moving items | dozens of pins visible | 2–3 visible cells |
| Playback engine | **no `AVPlayer`** for most pins | pooled `AVPlayer` (poolSize 3) |
| Asset needed | **dedicated lightweight `preview_url`** (short muted MP4 loop) | **the full stream URL** (HLS manifest) |
| Why | one player per pin is impossible for memory/perf | the same player instance must survive the hero zoom into full screen |
| Contract status | **blocked** — `RadarPin` cannot even express "this is a video" | **works today** off `cdn_url`; wants ABR + `asset_id` |

The map needs a *cheaper asset*. The gallery needs the *same asset* the
full-screen viewer will play. Those are opposite asks, and conflating them
breaks one surface or the other — see §"Why the gallery must not use
`preview_url`" below.

---

## Part 0 — Verified playback architecture (what drives the split)

### 0.1 Pooled players are correct; the "Instagram uses AVPlayer" premise is not

Bounded player pooling — a small fixed set of reusable player objects recycled
across cells rather than one player per cell — is the correct and near-universal
pattern for `AVPlayer`-based feeds, and it is what this client already ships
(`MediaPlayback.VideoPlaybackController`, `poolSize: 3`;
`MapVideoPlaybackCoordinator(maxConcurrent: 3)`).

**But it should not be attributed to Instagram's `AVPlayer` usage, because
Instagram does not use `AVPlayer`.** Meta's own engineering blog states that
Instagram for iOS "operate[s] on a decoupled architecture of lower-level
components rather than a typical high-level AVPlayer setup," feeding
independently-decoded buffers into an `AVSampleBufferDisplayLayer` so they can
handle codecs Apple does not vend (e.g. AV1 before the iPhone 15 Pro).

Two consequences for us:

- We should justify our pool from **`AVPlayer`'s own cost model** (each player
  holds a decode session; `AVPlayer` is documented as playing a single asset at
  a time and being reused via `replaceCurrentItem(with:)`), not from a claim
  about Instagram internals that is publicly contradicted.
- Meta's reported prefetch strategy — fetch only the **first 2–3 second chunk**
  before a Reel enters the viewport rather than the whole file — *is* directly
  applicable, and it is an argument for short HLS segments and a `faststart`
  moov atom on every rendition (see §A).

### 0.2 What actually preserves the playhead across the hero transition

The requirement is real: tapping a playing tile must fly into full screen
**without the video restarting**. The mechanism, however, is not "hand the same
`AVPlayerLayer` to the detail view."

What owns the playhead is the **`AVPlayerItem`**, not the `AVPlayer` and not the
layer. A pooled `AVPlayer` re-loaned with a *new* `AVPlayerItem` starts at
`CMTime.zero` — reusing the player object alone guarantees nothing.

The invariant is therefore:

> **The hero handoff must not call `replaceCurrentItem(with:)`, and must not
> construct a new `AVPlayerItem` for the same media.**

The supported way to show that one item on a second surface is to attach a
second `AVPlayerLayer` to the same `AVPlayer`. Apple's AVFoundation Programming
Guide documents both the capability and its one caveat:

> "You can create many AVPlayerLayer objects from a single AVPlayer instance,
> but only the most recently created such layer will display any video content
> onscreen."

That caveat is why a handoff needs a matching *hand-back*: after the transient
flight surface goes away, the original view has to re-attach to reclaim the
render slot, or it stays blank while the player keeps running.

This is already implemented in this repo and is the seam the gallery grid
plugs into:

- `VideoPlaybackController.mirror(from:to:)` — attaches the live player to the
  flight card's surface (two layers, one player, one clock; no item swap).
- `VideoPlaybackController.reclaim(_:)` — re-asserts the original view as the
  display surface on the way back, exactly per the most-recently-attached rule.
- `ZoomTransitionDestination.zoomMirrorLiveMedia(onto:)` /
  `PostGridFlightCard.adoptZoomLiveMedia(_:)` — the transition-side plumbing.

So: **same `AVPlayer` *and* same `AVPlayerItem`, mirrored onto a second layer,
then reclaimed on dismiss.** Timestamp continuity in both directions falls out
of never touching the item.

### 0.3 Why the gallery must not use `preview_url`

This is the load-bearing conclusion for the contract.

If the grid cell played a low-res `preview_url` and the full-screen viewer
played the full stream, then at the moment of the hero zoom the client would
have to swap to a different asset — a new `AVPlayerItem` — which resets the
playhead to zero and produces exactly the restart the feature exists to avoid.
A cross-fade between two items is not a fix: it doubles the decode sessions at
the worst possible moment (mid-spring) and still drifts.

The correct answer is to keep **one item** and let **ABR** move the quality:
open the HLS manifest in the grid cell with a low `AVPlayerItem.preferredPeakBitRate`
/ `preferredMaximumResolution` cap, and **raise the cap** on the same item when
the cell goes full screen. The ladder does the work the two-URL scheme was
trying to do, without ever breaking the item.

That is why the gallery's ask is "give us a proper HLS ladder with a low bottom
rung," not "give us a second URL."

The map has no such constraint — a pin that is tapped transitions into a
full-screen feed page which legitimately loads the real asset, and dozens of
pins can never each hold a player regardless. The map genuinely needs the
separate cheap file.

---

## Problem

1. **Map annotations / pin cards.** During pan/zoom we render up to Top-K pins
   per tile and want ≤3 of them animating.
   `geo_discovery.v1.RadarPin` carries `post_id`, `lat`, `lng`, `thumbnail_url`
   — nothing else. There is no way to know a pin is a video, and no lightweight
   clip to play. Playing the full asset here would destroy map fluidity even if
   we had its URL. **This surface is hard-blocked on a schema change.**
2. **For You / Profile gallery grid.** An Instagram-style pooled-player grid
   (2–3 concurrent visible cells) with player reuse across the hero zoom
   (§0.2). We hydrate full `PostView`s, so `cdn_url` is reachable — but it is
   the *original* asset: no ABR ladder, so 3 concurrent cells pull
   full-resolution bytes and there is no low rung for
   `preferredPeakBitRate` to select. **Not blocked, but unshippable at scale.**

Today the entire contract surface vends **one full URL + one still image** per
attachment. There is no "light" tier anywhere, and no ladder to cap into.

## Current contract reality

- `media.v1.RenditionKind` = `ORIGINAL | THUMBNAIL | SMALL | MEDIUM | LARGE` —
  image sizes only. `media.v1.MediaKind` = `AVATAR | POST_IMAGE` — no video.
  `Rendition`/`DeliveredRendition` have no `duration`/`bitrate`/`has_audio`.
- `post.v1.MediaAttachmentView` = `cdn_url`, `mime_type`, `width`, `height`,
  `thumbnail_url`, `duration_seconds`. **No `asset_id`**, so the client cannot
  call `ResolveDelivery` to select a lighter rendition — there is no id to
  resolve with.
- `geo_discovery.v1.RadarPin` = `post_id`, `lat`, `lng`, `thumbnail_url`.
  No media kind, no preview URL, no dimensions.
- `post.v1.PostSummary` carries no media; `search.v1.PostHit` carries only
  `thumbnail_key`.

`ResolveDelivery(asset_id, preferred: RenditionKind)` is already the right
seam — it just has no video/preview rungs to ask for.

---

## Proposal (all additive; no renumbering, no breaking change)

### A. `media.v1` — add the preview rung to the ladder

Beyond the video kinds already requested in `PHASE3_VIDEO_BACKEND.md` §1
(`MEDIA_KIND_POST_VIDEO = 3`, `MEDIA_RENDITION_KIND_HLS = 6`,
`MEDIA_RENDITION_KIND_POSTER = 7`, `MEDIA_RENDITION_KIND_MP4_720 = 8`):

```proto
enum MediaRenditionKind {
  // ... existing ...
  MEDIA_RENDITION_KIND_PREVIEW_LOOP = 9;      // NEW — map pins
  MEDIA_RENDITION_KIND_PREVIEW_ANIMATED = 10; // NEW, optional
}
```

- **`PREVIEW_LOOP`** — **the map asset** (§0.3: the gallery does *not* use
  this). Target spec: progressive MP4 (H.264 baseline or HEVC), **muted / no
  audio track**, ~2–3 s, short edge ≤ 480 px, ≤ ~300 KB, seamlessly loopable,
  `faststart` (moov atom first) so playback begins on the first range request.
- **`PREVIEW_ANIMATED`** — animated WebP (or GIF) for surfaces that cannot host
  an `AVPlayer`. **Secondary priority.** We do *not* want GIF as the primary:
  for equal pixels it is 5–20× the bytes of muted H.264, has no hardware decode
  path, and holds every frame in memory — the opposite of what map fluidity
  needs. Please treat MP4 as the primary preview format.

**HLS ladder requirement (the gallery's actual ask).** The `HLS` rendition must
include a genuinely low bottom rung — target ~360p at a few hundred kbps — and
short segments (2–4 s). The grid caps `preferredPeakBitRate` to that rung for
off-focus cells and lifts the cap on hero-zoom, all on one `AVPlayerItem`. A
ladder whose lowest rung is 720p gives us nothing to cap into and the grid will
pull near-full bitrate for every visible cell.

Also add to `Rendition` and `DeliveredRendition`:

```proto
uint32 duration_ms = 7;   // also requested in PHASE3 §1.3
uint32 bitrate_bps = 8;   // lets the client pick a cap without probing
bool   has_audio   = 9;
```

`bitrate_bps` is not cosmetic: it is what lets the client choose a
`preferredPeakBitRate` deterministically instead of guessing.

### B. `post.v1.MediaAttachmentView` — surface it where the client reads

```proto
message MediaAttachmentView {
  // ... existing 1-6 ...
  string asset_id          = 7;  // also required by PHASE3 §4a (write path)
  string preview_url       = 8;  // pre-resolved PREVIEW_LOOP
  string preview_mime_type = 9;
}
```

`thumbnail_url` keeps its meaning (still poster). `cdn_url` for a video
attachment should be the **HLS manifest** — that is the URL the grid opens and
carries into full screen unchanged (§0.3).

`preview_url` on `post.v1` serves non-player surfaces (and any future
low-power/Data-Saver mode), **not** the gallery grid's normal path.

**Preference:** have the BFF pre-resolve these during hydration rather than
making the client issue a `ResolveDelivery` per cell — a per-cell round trip is
exactly the latency the grid pool exists to avoid. `asset_id` is still wanted as
the escape hatch and for the write path.

### C. `geo_discovery.v1.RadarPin` — the actual map blocker

```proto
message RadarPin {
  // ... existing 1-4 ...
  media.v1.MediaKind media_kind = 5;  // client already reserves this field no.
  string preview_url            = 6;  // PREVIEW_LOOP; empty for stills
  uint32 width                  = 7;  // optional, for pre-layout
  uint32 height                 = 8;
}
```

Radar is served from the Redis pin projection with no card hydration, so these
must be **denormalized into that projection at index time**. Do not make the
pan path hydrate — that would trade one perf problem for another. Payload cost
is ~100 bytes/pin, acceptable at Top-K.

Apply the same two fields to `geo_discovery.v1.MapPostCard` (Focus path).

Note the map deliberately does **not** want `cdn_url` here. A pin must never be
able to start a full-stream fetch during a pan.

### D. Lightweight list paths (lower priority)

`post.v1.PostSummary` and `search.v1.PostHit` should carry `media_kind` plus
dimensions/preview so mosaic surfaces fed by summaries or search are not blind.
Overlaps with `BACKEND_MEDIA_ASPECT_RATIO_SUPPORT.md` — resolve together.

---

## Client contract (what we guarantee)

**Map surface**
- We play **only** `preview_url` on the map. We never open `cdn_url` from a pin.
- At most 3 pins animate concurrently
  (`MapVideoPlaybackCoordinator(maxConcurrent: 3)`); the rest render the still
  `thumbnail_url`. Off-screen pins stop and return their player to the pool.

**Gallery grid**
- At most 3 cells play concurrently, from a shared pool
  (`VideoPlaybackController(poolSize: 3)`).
- Off-focus cells are capped via `preferredPeakBitRate` to the ladder's bottom
  rung; the cap is lifted on hero-zoom **on the same `AVPlayerItem`**.
- The hero transition mirrors the live player onto the flight surface and
  reclaims it on dismiss (§0.2) — no item swap, no re-fetch, no second decode
  session, so the same bytes serve tile and full screen.

**Both**
- Previews/tiles play **muted and looping**; we never need an audio track on a
  `PREVIEW_LOOP`.
- We fall back to `thumbnail_url` whenever the video URL is empty, so partial
  rollout and backfill-in-progress are both safe.
- We route video purely on MIME (`video/*` or `application/vnd.apple.mpegurl`),
  so a correct `Content-Type` is load-bearing.

## Acceptance criteria

1. `QueryTile` returns pins whose video entries carry `media_kind = VIDEO` and
   a non-empty, client-reachable `preview_url`.
2. `curl` from a non-Docker host: `preview_url` returns `200`, correct
   `Content-Type`, and honours range requests.
3. A `PREVIEW_LOOP` rendition is ≤ ~300 KB and ≤ 3 s for a typical post; it has
   no audio track (`ffprobe` shows a video stream only).
4. `GetPost` returns `asset_id` on every video attachment, with `cdn_url`
   pointing at the **HLS manifest**.
5. The HLS ladder exposes a bottom rung ≤ ~480p / ~600 kbps with 2–4 s
   segments, and `bitrate_bps` is populated per rendition.
6. `ResolveDelivery(preferred = PREVIEW_LOOP)` returns the preview rendition
   for a `READY` video asset.
7. Backfill: existing video assets get a `PREVIEW_LOOP` rendition and a full
   ladder via `Reprocess`.

## Open questions

1. Preview segment selection — first N seconds, or a scene-detected "best"
   window? First-N is fine for v1.
2. Do we need `PREVIEW_ANIMATED` at all, or is muted MP4 sufficient everywhere?
   (Client prefers MP4-only.)
3. Should **image** posts also get a `PREVIEW_LOOP`-equivalent light rung for
   the map, or is `THUMBNAIL` already sized for pin display? What are
   `THUMBNAIL`/`SMALL` actual pixel targets?
4. Signing: is `preview_url` public/CDN-cacheable, or signed with
   `url_expires_at`? Map pans re-fetch pins constantly — short-lived signed
   URLs would defeat client-side caching.
5. Is the Radar Redis projection wide enough to absorb 2–4 more fields per pin
   without a memory-budget problem at current pin volume?
6. Does the CDN support HLS byte-range / partial segment fetch, so we can adopt
   the "first 2–3 seconds only" prefetch strategy (§0.1) for off-screen cells?

## References

- Meta Engineering, *Enhancing HDR on Instagram for iOS With Dolby Vision*
  (2025-11-17) — Instagram iOS uses a decoupled lower-level decode +
  `AVSampleBufferDisplayLayer` stack, not `AVPlayer`.
  https://engineering.fb.com/2025/11/17/ios/enhancing-hdr-on-instagram-for-ios-with-dolby-vision/
- Apple, *AVFoundation Programming Guide — Playback*: many `AVPlayerLayer`s per
  `AVPlayer`, only the most recently created one displays video.
  https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/02_Playback.html
- Apple Developer Forums, *How to use multiple AVPlayerLayers with one AVPlayer*
  — device-vs-simulator behaviour, detach-on-disappear.
  https://developer.apple.com/forums/thread/688766
