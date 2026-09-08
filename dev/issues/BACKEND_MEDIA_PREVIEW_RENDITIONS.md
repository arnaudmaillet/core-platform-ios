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

### C.1 Client status: the map half is built, and dark (verified 2026-09-07)

Everything §C asks for already has a client on the other side of it, wired end
to end and unreachable. Recorded here because the gap is not "not implemented
yet" — it is one `nil`, with the whole feature standing behind it.

Candidate selection needs two facts, and the wire supplies neither
(`Maps/MapsViewController.swift:1866-1868`):

```swift
guard let pin = spokenPin, let host,
      pin.kind == .video,
      let url = pin.previewVideoURL,
```

- `pin.kind` — `GeoDiscoveryRepository.kind(for:)` (`:163`) classifies every
  covered pin as `.photo` in a release build. `.video` exists only inside
  `#if DEBUG`.
- `pin.previewVideoURL` — `previewVideoURL(for:kind:thumbnailURL:)` (`:185`)
  returns `nil` outside `#if DEBUG`, unconditionally and by design: `RadarPin`
  has no URL for it to return.

So `MapVideoPlaybackCoordinator.playing` is empty for the life of a release
build, and it is the only thing that can put a live player on a marker.

⚠️ **The two gates do not open on the same switch**, which matters when reading
a simulator run. The kind gate opens with **no launch argument** in DEBUG — the
mock's `mock-kind=video` stand-in for field 5 (`:176`), added so the map has
video pins at all — so play badges appear. The URL gate opens **only** under
`-maps-force-video` (`:187`). A DEBUG map of badged video pins with nothing
moving is the expected default, not a defect.

**What that makes DEBUG-only, and the scope is narrower than it first looks:**

| Client behaviour | Production, MAP route |
|---|---|
| `MapPinZoomSource.zoomFlightCarriesLivePlayer` (`:229`) | always `false` — `MapVideoPlaybackCoordinator.isLivePreviewing` cannot be true with `playing` empty |
| `SnapFeedViewController.defersPlaybackForStagingFlight` (`:169`) | always `false` — it ANDs the source's own answer, handed over at `ZoomTransitionController.swift:139` |
| `SnapFeedCell.warmAttachForFlight` | never called — it sits behind that deferral |
| `ZoomAnimator`'s destination-mirroring `ZoomLiveMediaRetry` (`:338`) | **always armed** — it is gated on `!zoomFlightCarriesLivePlayer` |

⚠️ **SCOPED TO THE MAP, NEVER TO THE MECHANISM, and the difference has already
been got wrong once.** `zoomFlightCarriesLivePlayer` defaults to `true` on the
protocol (`ZoomTransition.swift:198`) and **`MapPinZoomSource` is the only
source in the repo that overrides it**. So every For You / Profile grid flight
carries a live player and defers in production — `SnapFeedViewController`'s own
comment says the deferral is "load-bearing" there — and those flights land
through the same `zoomAdoptLiveMediaView` -> `SnapFeedCell.adoptLiveRenderView`
path the map's would. The deferring ORDERING is ordinary production behaviour.
What is DEBUG-only is reaching it *from a map marker*.

**What a run under `-maps-force-video` tells you, and what it does not.** The
flag does not make a map pin behave like a production map pin. It makes it
behave like a *grid* cell — a marker that flies a live player — so a rate
measured under it is a rate for the grid's ordering wearing the map's clothes.
Bugs found in that window are usually real; their reproduction rate, and
sometimes their trigger, are artifacts of the flag.

This has already cost twice, in opposite directions. A merged PR description
first explained *why a spinner only sometimes stuck* with the deferred-page
ordering as though it were the map's own — wrong, and withdrawn. The correction
then over-swung to "that ordering does not exist in production" — also wrong,
because it does, on every grid flight. The defect and its fix were sound
throughout; only the account of WHERE it is reachable moved.

The rule, for anything measured on this surface until §C ships: before
attributing a rate or a cause to production, name the flag-free route to the
same defect, or say plainly that it is DEBUG-only today. Both are useful
answers. A rate collected under the flag and reported as production behaviour
is not.

**The day fields 5 and 6 land.** Nothing in the client's playback stack changes
shape; two branches are deleted:

- `kind(for:)`'s media branch becomes a read of the wire's own kind. The client
  already reserves field 5 for it (§C above) — and it needs the enum case as
  well as the field: `media.v1.MediaKind` is `AVATAR | POST_IMAGE` today
  ("Current contract reality"), so the video case named in §A is part of the
  same landing. Field 6 alone would classify every video pin as a photo and
  never ask for its preview.
- `previewVideoURL` returns the wire's preview URL, and `-maps-force-video` is
  deleted with it.

The consequence worth stating in advance: **the ordering that is a flag artifact
on this route today becomes the ordinary map open.** A video marker that is
previewing when it is tapped really will fly a live player, the destination
really will defer, and `warmAttachForFlight` really will run — so every
transition measurement taken on the map under the flag is worth re-running
without it. Acceptance criteria 1 and 2 are what gate that switch.

### C.2 The thumbnail is not a second asset — it is the sheet's first cell

Verified in the client on 2026-09-08, and it changes what we are asking for.

A media post's picture is drawn as a ladder, and every surface keeps it:

```
live media  ->  sprite sheet  ->  thumbnail  ->  black
```

The thumbnail is the second-to-last rung, and its ONLY correct value is the
first frame of the clip. Anything else is a picture of something the post is
not, and the viewer sees it as the post changing its mind: the still is what a
marker shows before its sheet resolves, what a hero flight carries, and what the
page shows until the first frame decodes — three places, one picture.

**So `thumbnail_url` for a video post should be a rendition of the preview
sheet's own cell 0, not an independently chosen still.** One asset, two uses.
Serving them separately guarantees they will drift, and the drift is visible:
in our own fixtures a thumbnail picked independently of the sheet produced a
marker showing a black title card over a post whose flight animated a forest —
both frames of the same film, neither the same picture.

Concretely, on top of §C:

- `preview_sheet.first_frame_url` (or an agreed convention such as the sheet's
  cell 0 at the sheet's own cell size), and `thumbnail_url` resolving to it for
  any post that HAS a sheet.
- Where a post has no sheet, `thumbnail_url` must still be a frame of its own
  clip — the encoder already has it; the client cannot derive one without
  fetching the media it was trying to avoid fetching.
- The client's fallback if neither is served is BLACK. It is not a stock
  picture, and it must not be an unrelated photograph: we removed two of those
  from our own mock the same day.

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
