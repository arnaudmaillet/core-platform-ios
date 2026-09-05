# Backend: animated icons for text-only posts — map markers and chat emotes

**Service:** `geo_discovery.v1` (+ a new catalog RPC; `chat.v1` optional)
· **Status:** proposal — no field exists yet, so the wire shape is still ours to choose
**Client:** iOS Maps tab (every text marker, every zoom, every pan) and the chat transcript
**Related:** `dev/BACKEND_GAPS.md` §15 (`RadarPin` renditions), §18 (semantic
clusters), `dev/issues/BACKEND_MAP_PIN_AUTHOR.md` (same marker slot),
`dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` (§C, and a client guarantee
this proposal voids), `dev/issues/BACKEND_H3_BOUNDING_BOX.md` (field-number
collision)

## Summary

A text-only post has no cover, so its marker wears a glyph — or, once
`BACKEND_MAP_PIN_AUTHOR` lands, the author's avatar. The product wants a third
option above both: an **animated icon** attached to the post, drawn on the
marker in place of the avatar.

The requirement is unqualified: **every marker wearing an icon animates, all
the time.** Not the selected one, not the three most central — every one.

That single word "every" is what makes this a contract question rather than a
client one. The client can render it; what the client cannot do is survive the
shape of payload this feature would naturally be given.

**The one ask that matters most is §3 (Ask C):** where an icon's motion is a
rigid mark being scaled, rotated or faded, send ONE picture and three curves
instead of a strip of frames. Measured on the worst case — 128 markers on the
saturated lattice — that is **9.0 MB against 216.8 MB**, and it is the
difference between the feature fitting in the client's icon budget and evicting
mid-pan. Everything else in this document is the fallback for artwork that
cannot be expressed that way.

## Why this is not just another URL field

The map's clustering engine guarantees that no two markers are closer than
64pt on screen (`MapClusterEngine`, collision cell = marker footprint + 8pt).
That bounds the viewport to a packed lattice:

| Device | Lattice | Simultaneous markers |
|---|---|---|
| 440×956pt (17 Pro Max class) | 8 × 16 | **128** |
| 375×667pt (iPhone SE 3) | 7 × 12 | **84** |

Two properties make this the *realistic* number rather than a pathological one:

- **The lattice saturates.** For any corpus denser than a viewport's worth,
  clustering does not thin the markers below the lattice — it fills it. In any
  populated city, at any zoom, the count is the maximum.
- **The whole screen can be text.** `MapClusterEngine.representative(of:)` is
  kind-neutral by deliberate design ("Popularity is a POST judgement, not a
  format one" — an earlier media-preferring rule was reverted). A cluster whose
  most-liked member is a text post wears the text face, and therefore the icon.
  On top of that, the client classifies **any pin with an empty
  `thumbnail_url`** as text — including a media post whose thumbnail the
  pipeline never generated.

So the design target is 128 concurrently animating icons, not a handful.

**The consequence for the wire.** On iOS, memory is a function of the number of
**distinct images** resident, not the number of things drawing them: layers
sharing one image share its backing store. So the marker count is nearly free
and the *variety* count is not:

Measured at the client's real geometry — a 136px cell, 12 frames, RGBA — one
resident atlas is **867 KB**:

| Wire shape | Distinct images on screen | Resident texture |
|---|---|---|
| Enumerated catalog id (typical screen, ~20 distinct) | 20 | **~17 MB** |
| Enumerated catalog id (pathological, 64 distinct) | 64 | ~56 MB |
| Free-form per-post asset URL, 12 frames | 128 | **108 MB** — measured |
| Free-form per-post asset URL, 24 frames (the cap) | 128 | **~217 MB** — jetsam |

And the sharing guarantee is precisely what makes the free-form branch
unrecoverable rather than merely expensive: an image assigned to a live layer is
retained by the render tree, so a cache can evict only what is already off
screen. There is no client-side mitigation, and no third-party rendering
library changes it — they all decode into per-instance surfaces, which is worse.

**Hence the shape of this ask: an enumerated id on the pan path, and free-form
assets only where the on-screen count is one.**

## What already exists, and why it does not answer

- `RadarPin` is `post_id / lat / lng / thumbnail_url`. Nothing else.
- **Do not overload `thumbnail_url`** with a scheme (`icon://sparkles`,
  `emote:42`). Recorded here so it is not proposed later: the client classifies
  any non-empty `thumbnail_url` as a media post, and every deployed client
  would both mis-render the marker as a photo *and* fire an HTTP fetch at a
  non-HTTP URL. This is a breaking change disguised as an additive one.
- `MapPostCard` (the `GetGeoTimeline` Focus path) is the right home for a
  free-form asset, but it is reachable only **after a tap** — the cold read the
  Radar pan path deliberately avoids. It cannot serve the marker.

---

## 0. BLOCKING: reconcile the `RadarPin` field-number ledger first

Three in-flight proposals already collide on `RadarPin`, before this one adds
anything:

| Field | Claimed by | Source |
|---|---|---|
| 5 | `media.v1.MediaKind media_kind` | `BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §C |
| 5 | `string author_avatar_url` | `BACKEND_MAP_PIN_AUTHOR.md` — **collision** |
| 6 | `string preview_url` | `BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §C |
| 6 | `string author_id` | `BACKEND_MAP_PIN_AUTHOR.md` — **collision** |
| 6 | `int64 h3_index` | `BACKEND_H3_BOUNDING_BOX.md` §A — **collision** |
| 7, 8 | `uint32 width`, `uint32 height` | `BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §C |

`BACKEND_H3_BOUNDING_BOX.md` already flags part of this in its own text
(⚠️ *"field 5 is RESERVED for media_kind"*) but then takes 6, which the
renditions proposal had also taken. None of the four proposals can land until
one ledger is adopted **as a whole**.

Proposed reconciliation — seniority order, oldest proposal keeps its numbers:

```proto
message RadarPin {
  string             post_id           = 1;   // shipped
  double             lat               = 2;   // shipped
  double             lng               = 3;   // shipped
  string             thumbnail_url     = 4;   // shipped; empty => text-only post

  media.v1.MediaKind media_kind        = 5;   // MEDIA_PREVIEW_RENDITIONS §C
  string             preview_url       = 6;   // MEDIA_PREVIEW_RENDITIONS §C
  uint32             width             = 7;   // MEDIA_PREVIEW_RENDITIONS §C
  uint32             height            = 8;   // MEDIA_PREVIEW_RENDITIONS §C

  int64              h3_index          = 9;   // H3_BOUNDING_BOX §A   (was 6)
  string             author_avatar_url = 10;  // MAP_PIN_AUTHOR       (was 5)
  string             author_id         = 11;  // MAP_PIN_AUTHOR       (was 6)

  uint32             icon_id           = 12;  // ← THIS PROPOSAL
}
```

No field here is shipped beyond 4, so the renumbering costs nothing today and
costs a migration the moment any one of them ships alone.

---

## 1. Ask A — `RadarPin.icon_id`

```proto
// The animated face a TEXT-ONLY post wears in place of the author avatar.
// 0 or absent = no icon; the marker keeps the avatar/glyph it draws today.
uint32 icon_id = 12;
```

Invariants requested as server guarantees (the client enforces them defensively
either way):

- Range `1 .. 1024`. An id outside the range, or absent from the catalog
  version the client holds, **falls back to the avatar/glyph** — never an
  error, never a fetch, never a blank marker.
- Set **only when `thumbnail_url` is empty**. A pin carrying both a cover and an
  icon is a server bug; the client ignores `icon_id` when a cover is present.
- Denormalized into the Redis pin projection **at index time**, like the
  renditions fields. The pan path must not hydrate to resolve it.

**Why an enum and not a URL, in bandwidth terms** (the memory argument above is
the primary one): a `uint32` varint at these ids is ≤3 bytes with its tag; a CDN
URL is ~60–80. At a 200-pin Top-K response that is **~600 B versus ~14 KB per
pan**, on the highest-frequency path in the product.

## 2. Ask B — the icon catalog

A new message, served once and cached on disk by the client, keyed by version.

```proto
message AnimatedIcon {
  uint32 id          = 1;  // matches RadarPin.icon_id; 1..1024
  string slug        = 2;  // "sparkles" — ALSO the chat shortcode. [a-z0-9_]{1,24}
  string sheet_url   = 3;  // ONE sprite sheet, PNG or HEIC, alpha required
  uint32 frame_count = 4;  // 1..24
  uint32 columns     = 5;  // grid width; rows = ceil(frame_count / columns)
  uint32 cell_px     = 6;  // MUST be 136 (see §4)
  uint32 frame_ms    = 7;  // one of {33, 50, 66, 83, 100}; 33 preferred (§4)
  string label       = 8;  // VoiceOver text, localizable
}

message AnimatedIconCatalog {
  uint32                version = 1;  // bumped on ANY change
  repeated AnimatedIcon icons   = 2;  // <= 1024
}
```

Delivery can be an RPC (`GetAnimatedIconCatalog(version) -> catalog | not-modified`)
or a versioned static JSON/protobuf on the CDN. The client only needs: fetch
once, cache on disk, re-fetch when a served `icon_id` is unknown or on a version
bump. A stale catalog is safe — unknown ids fall back — but it means a newly
published icon is invisible to clients until they re-fetch, so a cheap version
probe on app launch is worth having.

## 3. Ask C — the preferred asset: one still plus a motion track

**Where an icon's motion is a rigid mark being scaled, rotated, translated or
faded, do not ship frames at all. Ship one picture and three curves.**

This is the single highest-leverage line in this document. It is worth 24x the
memory of everything else here combined, and it costs the pipeline less work
than the sheet does, not more.

```protobuf
message AnimatedIcon {
  // ... fields from Ask B ...

  // Present when the icon's motion is affine. The client then needs NO frames.
  MotionTrack motion = 10;
}

message MotionTrack {
  // Samples over one loop, evenly spaced.
  //
  // ⚠️ NOT bounded by `frame_count <= 24`. That cap is Ask D's, and it exists
  // because a frame is 72 KiB of texture; a sample here is three floats. Sample
  // at the fastest rung the loop allows (33 ms) and cap around 120. Applying the
  // sheet's cap to a track is a category error that costs smoothness for
  // nothing: a two-second loop capped at 24 came out as an 83 ms step, and the
  // icons visibly stepped at 12 fps on a screen asking for 30.
  repeated float scale    = 1;   // 1.0 = authored size
  repeated float rotation = 2;   // radians, may exceed 2pi for a full spin
  repeated float opacity  = 3;   // 0.0-1.0
  uint32 frame_ms         = 4;   // as in Ask B
  // Optional; omit a channel that never moves. The client installs one
  // animation per MOVING channel, so a constant channel costs nothing.
}
```

The still itself is one cell obeying every invariant in Ask D (136px, 2px
gutter, circular alpha pre-baked, HEIC preferred).

### Why this matters more than any other decision in this document

A sprite sheet is a **cache of a computation the compositor performs anyway**.
Core Animation applies scale, rotation and opacity to a layer for free, on the
render server, out of our process. Recording 24 pre-transformed copies of the
same picture buys nothing and costs 24x.

Measured on the instrument (`-icon-bench`, iPhone 17 Pro Max simulator, 128
markers on the saturated 64pt lattice, 136px cells, 24 frames):

| | resident, 16 distinct | projected, 128 distinct | cold dress |
|---|---|---|---|
| Sheet (Ask D) | 27.1 MB | **216.8 MB** | 1.04 s |
| Still + track (Ask C) | **1.1 MB** | **9.0 MB** | 0.49 s |

**24x, and it is the difference between shippable and not.** At 128 distinct
the sheet path does not merely cost more — it does not fit: the client's 48 MB
icon budget evicts and re-bakes mid-pan, where the whole decomposed catalog is
resident in 9 MB with room to spare.

The two are the same picture. Verified pixel by pixel against the sheet the
same pipeline would have produced: **worst mean error 0.51/255 across all 16
catalogue icons, and exactly 0.0000 on every frame whose pose is identity.** The
residual is antialiasing on the disc rim.

### The second win: smoothness stops costing memory

On a sheet, fluidity is bytes — 60 fps means 60 cells. On a track it is
keyframes of a curve, so the client can interpolate and the price moves entirely
onto composite rate, which is a per-surface battery decision rather than a bake
decision taken once for everybody:

| | 30 fps | 60 fps |
|---|---|---|
| Sheet, 128 distinct | 216.8 MB | **541.9 MB** |
| Still + track, 128 distinct | 9.0 MB | **9.0 MB** |

So the answer to "can the icons be genuinely fluid" is **yes, and for free in
memory**. Measured on the worst case, 128 markers, with assets the baker really
produced:

| playback | presented | textures | app CPU | hitches |
|---|---|---|---|---|
| stepped, 61 keys @ 33 ms | 29.7 fps | 1.1 MB | 5.7% | 0 |
| continuous, same keys | **59.3 fps** | **1.1 MB** | 5.7% | 0 |

The two memory figures are the same number, not similar ones — interpolating
between keyframes allocates nothing.

### The rate policy, and where it does and does not apply

Product decision, now measured rather than assumed: **60 fps in normal use,
30 fps in Low Power, no motion at all in the fallback state** (Reduce Motion or
serious thermal pressure — posed and static, never blank).

It holds on the DECOMPOSED path, on both surfaces, and the frame rate is very
nearly free:

| surface | 15 fps | 30 fps | 60 fps | resident |
|---|---|---|---|---|
| map, 128 markers | — | 6.1% CPU | 6.3% CPU | 1.2 MB at every rate |
| chat, 684 emotes | 10.7% CPU | 11.4% CPU | 12.0% CPU | 1.2 MB at every rate |

Quadrupling the rate costs **1.3 points of app CPU and 0.0 MB.** The three policy
states measured end to end: 60.0 / 30.0 / 0.0 fps presented, 1.2 MB in all three
— the picture never changes, only how often it moves.

The resident figure now includes the track arrays, not just the texture. It had
to: counting only the texture made "frame rate costs no memory" true by
construction of the metric, since the texture is the one thing frame rate does
not scale. At 120 keys the samples are 2.9 KB per icon, ~368 KB across 128 — 4%
of the total. Small is a result; zero was a bookkeeping error.

⚠️ Two things the measurement forced, both counter-intuitive:

- **Low Power must give up interpolation, not just ask for less.** Halving
  `preferredFrameRateRange` changed nothing — measured 60.0 fps presented under
  a 30 Hz ceiling — because that hint is a *ceiling request*, not a throttle.
  Decimating keys changed nothing either while the client was interpolating
  between the survivors. The only lever that removes change instants is discrete
  steps, so the reduced state forces them.
- **684 is a stress ceiling, not a product number.** It is a uniform
  full-screen lattice at 26pt pitch. The real transcript cannot produce it: at
  the shipped cell geometry the maxima are ~170 for one-line spam, ~276 for
  four-line walls, ~382 for one pathological message. Bench against 684, quote
  ~400.

⚠️ **The policy does NOT hold on the sheet path, and that is the whole reason
§3 matters.** Same request, same screen:

⚠️ And note what "a sheet at 60 fps" required: **lifting the contract's own
`frame_count ≤ 24`**. Under the cap the sheet does not get expensive, it gets
WRONG — `frameCount` clamps to 24, the step stays at the requested 16.67 ms, and
a one-second loop plays in 0.4 s. Asking a sheet for 60 fps buys 2.5x the speed,
not 2x the smoothness. Both outcomes are bad; only one of them is visible in a
memory graph.

| at 60 fps, 128 distinct | textures | peak footprint |
|---|---|---|
| still + track (§3) | **1.2 MB** | 99 MB |
| sprite sheet (§4) | 46.6 MB resident, **541.9 MB projected** | 200.6 MB |
| GIF, client-decoded | 45.2 MB resident, 361.2 MB projected | **839.1 MB** |

**And a GIF cannot deliver 60 fps at all.** GIF89a stores its inter-frame delay
in *centiseconds*, so the representable rates are exactly 100/k — 100, 50, 33.3,
25, 20, 16.7 … **60 is not among them**, and neither is 30. Asking a GIF for
60 fps is not expensive, it is undefined. Measured presented rate on that path:
30.0, imposed by the client's resampling ladder rather than by the request.

So the rate policy is a property the backend must make possible, not one the
client can impose: **it is only available on assets that arrive as a still plus
a track.**

⚠️ **Free in memory and CPU is not free in battery.** Continuous playback means
every marker changes on every display refresh, so the whole screen composites at
60 Hz — precisely what the shared-epoch quantisation exists to avoid, and Apple
prices halving that at up to 20% of battery drain (WWDC22, *Power down*). The
instrument cannot see render-server cost, so which surface gets `continuous` is
a decision for Instruments on a device, not for this table.

### What decides which ask applies

Ask C where the motion is a rigid mark under an affine transform: spins, pulses,
heartbeats, bobs, flickers, drifts. Ask D where the pixels themselves change: a
face blinking, a flame licking, anything hand-animated frame by frame.

**Please mark this per icon in the catalog rather than guessing globally**, and
please do not synthesise a track for artwork that does not have one. A field
that is half decomposed and half sheeted is fine and expected — the client
handles both and reports the mix — but a track that does not reproduce its
artwork is a defect nothing downstream can detect.

If the source is Lottie, the reduction itself is close to free: a transform-only
composition IS this message, and extracting it at publish time is a walk over the
document's `ks` and `tr` objects. `Scripts/lottie-decomposability.py` does exactly
that walk and prints the verdict per file.

### ⚠️ But do not expect existing Lottie artwork to qualify

Run against the twelve real dotLottie files already shipping in this app (the
chat sticker strip), that script returns:

    1 / 12 decomposable

Not because the motion is exotic — the affine property count dwarfs the raster
one in almost every file (Book: 334 affine against 51 raster) — but because a
handful of **animated gradient endpoints, stroke widths and colours** are
sprinkled through each one, and a single raster property forces the whole icon
onto a sheet. Three files are within *six* such properties of qualifying
(Weather: 2, Cars: 5, NoEntry: 6), and six of the twelve are within ten.

Two conclusions, and they point the same way:

1. **Ask C is a constraint on how icons are AUTHORED, not a property to hope
   for.** "No animated gradients, no animated stroke widths, no animated fill
   colours — move it, scale it, rotate it, fade it" belongs in the icon design
   guide. That one rule is worth the 24x.
2. **The pipeline must check rather than assume.** A file that looks affine and
   is not produces an icon that does not match its artwork, and nothing
   downstream can detect that.

Caveat on the sample: those twelve are 200px hand-drawn chat stickers, which are
a different artwork class from a 44pt map mark. They are evidence about what
designer-authored Lottie looks like by default, not a prediction of the map
catalog's rate. But "by default" is the point — the rate is a decision, and
somebody has to take it before the artwork is commissioned.

## 4. Ask D — the fallback asset format: a sprite sheet, not a GIF

For artwork Ask C cannot express — anything whose PIXELS change rather than its
position — this is the format. It is still the second-best answer, and here is
the reasoning in full.

**Serve each icon as ONE still image containing every frame in a grid**, plus
the geometry in the catalog above — **HEIC preferred over PNG**. Not a GIF, not
an APNG, not a Lottie JSON.

Two arguments that are commonly made for this and that we are NOT making, because
they were tested and they do not hold:

- ~~"The client has no animated-image decoder."~~ **It does.** iOS 26 decodes
  GIF, APNG, animated WebP, HEICS and animated AVIF natively through ImageIO
  (`CGImageSourceCopyTypeIdentifiers()` returns 59 UTIs; a 30-frame decode runs
  correctly on a background queue). There is no decoder to add.
- ~~"A sheet is smaller on the wire."~~ **It depends on frame count and it is a
  wash at our operating point.** At 30 frames/132px a HEIC sheet is 118 KB
  against animated WebP's 137 KB; at 12 frames/136px, HEICS is 34.1 KB against
  the sheet's 42.1 KB — the animated container wins by 20%. Do not argue size in
  either direction.

The real reasons, all of which survive:

- **One sheet is one texture, and it is one decode.** 128 markers wearing the
  same icon share one resident image; the animation is a per-layer window
  sliding over it. This is the entire cost model, and it is what makes 128
  concurrent icons affordable at all.
- **It moves the bake off the device.** Every animated container has to be
  unpacked to frames before it can be played this way, and that cost is real:
  128 distinct HEICS icons measured **10.8 s to bake** (8 cores, simulator),
  against one still decode for a sheet. A pan *is* first sighting — it reveals a
  dozen new markers at once — so a client-side bake lands on exactly the wrong
  moment.
- **It removes a whole class of silent failure.** The client's current decoder,
  handed a GIF, returns **frame zero with no error**. An "animated icons"
  release would ship as a "static icons" release and pass every existing test.
- **GIF specifically is disqualified** — on the format spec, not on speed (GIF is
  in fact the fastest thing here to decode). GIF89a provides a single
  *Transparent Color Index*: transparency is binary on/off, with no partial
  alpha, and the palette is 256 colours. On a 44pt disc over live map tiles that
  is an aliased cut-out rim on all 128 markers, plus banding on any gradient.

Asset invariants requested of the pipeline:

| Invariant | Why |
|---|---|
| Square cells, row-major, `frame_count` ≤ 24 | The client precomputes one unit-space rect per frame. |
| `cell_px = 136` | 132px is the marker disc at @3x; **plus a 2px fully transparent gutter**. |
| The 2px gutter is mandatory | The same sheet is minified to ~66px for a chat emote and ~88px on a @2x device. Without a transparent gutter, bilinear sampling bleeds the neighbouring frame into the icon's rim. This is a silent, ugly, hard-to-attribute defect. |
| **Circular alpha pre-baked** into every frame | The marker is a 44pt disc. If the asset is already round, the client sets no mask — and a mask on an animating layer costs an offscreen render pass *per marker per frame*, which at 128 markers is the single largest cost in the feature. Pre-baking the circle on the server removes it entirely. |
| `frame_ms` from a fixed set: **33, 50, 66, 83, 100** (30, 20, 15, 12, 10 fps), **33 preferred**. The set deliberately excludes **24 fps**. | One rate per icon — see below. |
| ≤ 512 KB encoded per sheet | Bounds the catalog's download and disk footprint. |
| **HEIC preferred over PNG** for `sheet_url` | At 30 frames, 118 KB against PNG's 260 KB, with alpha preserved (241 → 256 distinct levels, alpha RMSE 0.24%). One still decode, and HEVC hardware decode is universal on device. |
| Sheets are immutable per `id` + `version` | Lets the client cache aggressively with a long `Cache-Control`. |

### Why those frame rates, and why not 24

Three independent reasons, in descending order of how well they are sourced:

1. **Apple's own guidance for this exact content class.** The ProMotion
   documentation's frame-rate table gives "small, low-speed animations (clock
   ticking, progress bars)" a range of **8–48 Hz**, and says verbatim that
   "smaller movements — like an icon that rotates in-place — may look just fine
   at a lower rate", with the instruction to "choose the lowest frame rate that
   achieve's your desired visual flow" [sic]. A 44pt disc animating in place is
   literally the documented example.
2. **Texture budget.** Frame count is the one cost that scales linearly and
   certainly. At 132×132 RGBA a frame is ~68 KB; a 60 fps set is roughly **1.8×
   over** the client's 48 MB atlas cache, which converts a memory cost into a
   recurring evict-and-re-fetch cost. 30 fps is marginal; 15 fps fits
   comfortably.
3. **24 fps is the worst available choice for a mixed fleet.** It is a native
   ProMotion step (120/5) but it is **not a divisor of 60**, so on every
   non-ProMotion iPhone it plays 3:2 and judders visibly. 12, 15, 20 and 30
   divide both 60 and 120 exactly. 24 is the number film instinct reaches for
   and it is the one to exclude.

**One rate per icon, and it should be 30 — the halving is the client's job, not
the contract's.**

An earlier draft of this document asked for two rates: 15 fps for map markers and
30 for chat emotes. That was wrong on its own terms, for a reason worth recording
so it is not reintroduced: **an icon is ONE sprite sheet, shared by both
surfaces.** A sheet has one frame count and one authored rate. A contract cannot
express two.

30 fps is the right number to author at, for two reasons that agree:

- It is what the closest shipped precedent presents for dense small animated
  elements. Telegram's Lottie animation cache hardcodes a frame skip of 2 against
  its own 60 fps authoring spec, unconditionally, on every device — so its inline
  custom emoji, reactions and emoji keyboard all present 30.
- Perception favours the higher rate on the *map*, not the chat, which is the
  opposite of what the earlier draft assumed. Judder tracks per-frame
  displacement in screen pixels, and a marker is a 44pt disc against a ~22pt
  inline emote — roughly twice the displacement for the same motion. If anything
  the map is the more demanding surface.

**Where the halving belongs.** There is one genuine reason to run markers slower,
and it is narrow: a map that is open and *stationary* is the only state in which
the display would otherwise idle toward its 10 Hz floor, so the markers become
the only thing setting the refresh rate (WWDC22, *Power down*: "the display's
refresh rate is determined by the animation with the highest frame rate in your
app"). In a live chat the screen is already being driven by arriving messages and
scrolling, so emotes are not what sets the rate.

That is a battery argument about one state, not a rendering-quality argument, and
it is **currently an estimate rather than a measurement**. It therefore belongs on
the client, where it costs nothing to implement and nothing to reverse: playing
every other rect of a 30 fps sheet yields 15 fps from the same asset — Telegram's
`frameSkip`, applied at playback instead of at cache-build. The client can even
scope it to the state that motivates it (decimate once the map has been still for
a few seconds, run full rate while the viewer is interacting), which no contract
value could express.

**What the backend must not do** is bake the decision in by shipping 15 fps
sheets: that would cap the chat surface too, and it cannot be undone client-side.

**⚠️ And playback decimation buys nothing for MEMORY — `frame_count` is the only
lever there.** Halving the presented rate leaves the whole sheet resident, so at
30 fps the frame cap is doing all the work: at 12 frames a 136px sheet is ~867 KB
and the client's 48 MB atlas cache holds ~56 distinct icons; at 24 frames it is
~1.7 MB and the cache holds ~28. That is why `frame_count ≤ 24` is a hard
invariant and not a style note — and why a 30 fps icon must be a *short* loop
(24 frames at 33 ms is 0.8 s), not a long one.

### If the pipeline cannot bake sheets — the fallback ladder, in order

0. **A still plus a motion track (Ask C)** wherever the artwork allows it.
   Cheaper for the pipeline than any rung below, and 24x cheaper for the client.
1. **Server-baked sheets.** The ask above.
2. **Serve dotLottie (or HEICS) and let the client bake once, cached to disk.**
   This is genuinely viable and is not a consolation prize: a vector re-renders at
   any `cell_px`, so a future @4x or a different surface costs no re-bake, where a
   sheet is pixels at one scale. Measured price for the vector route: **one remote
   package in a module that has none today** (ThorVG — MIT, SPM, no transitive
   dependencies, 1.7 MB, pure C API), and **757 ms single-threaded / 225 ms on
   four threads** to bake 128 distinct 12-frame icons off the main thread.
   Note the incumbent library cannot do this job: lottie-ios took **14.6 s of
   *main* thread** for the same work and crashed 3/3 attempts off-main.
   ⚠️ And it does **not** remove the need for a server-side Lottie parser: ThorVG's
   *parse* is super-linear (5.1 ms at 302 shapes → 145.9 ms at 2 416), so a
   heavy-file guard cannot live on the client — by the time it can measure, it has
   already paid. The budget must be enforced at publish.
3. **Client-bundled catalog**, backend serves only `icon_id`. What the client
   does while this is in flight (§9) — but icons can then only be added in an app
   release, which defeats the point of a server-driven catalog.

For a *raster* wire the trade is worse than for a vector one, not better: the
client bake is cheaper to add (ImageIO, no package) but buys nothing, because the
server already produced pixels either way. **If the backend can emit an animated
raster container, it can emit a grid.**

### Measured: what a GIF/APNG wire actually costs on the marker field

Playback is unaffected — a container is baked to an atlas at ingest and then
plays through exactly the same `contentsRect` animation, with the same shared
epoch and the same zero per-frame app CPU. **The wire format changes only the
bake.** What it changes about the bake is not small (128 markers, saturated
lattice, 17 Pro Max simulator):

| wire | projected @128 distinct | **peak footprint** | distinct clocks | presented |
|---|---|---|---|---|
| still + track (Ask C) | **9.0 MB** | **90.8 MB** | 1 | 30 fps |
| server-baked sheet (Ask D) | 216.8 MB | 117.2 MB | 1 | 30 fps |
| real GIFs, client-decoded | 145.4 MB | **427.6 MB** | **3** | **10 fps** |
| 24-frame GIF, client-decoded | 216.8 MB | **546.4 MB** | 1 | 30 fps |

Three things that only show up on the real files:

1. **The peak, not the resident, is the danger.** Resident caps at the client's
   48 MB budget because the cache evicts; the peak is 128 concurrent ImageIO
   decodes each holding full-size frame buffers. And **a pan IS first sighting** —
   it reveals a dozen new markers at once — so the peak lands on the most common
   interaction on the screen. (Throttling bake concurrency trades this peak for
   dress time; not yet measured.)
2. **The shared clock breaks.** `distinct clocks = 3`: every file carries its own
   per-frame delays, and they vary *inside a single file* (0.2 s, 1.2 s and 2.5 s
   in the same GIF). Markers stop changing on a common grid, so the whole
   composite-rate argument for a quantised tick — and its battery win —
   evaporates. Note the presented rate: **10 fps for 30 asked.** The files impose
   their cadence, not us.
3. **GIF specifically** adds the format defects already listed above: binary
   alpha (an aliased rim on all 128 discs, rescuable at bake time by compositing
   onto our own antialiased disc — 55 alpha levels -> 2 -> 42) and a 256-colour
   palette. Loop lengths from 0.18 s to 56 s also mean the 24-frame cap compresses
   time hard.

**Conclusion: an animated container is fine as the escape hatch (§5), where one
asset is on screen after a tap. It is not viable as the marker field's wire.**

## 5. Ask E — the escape hatch for arbitrary per-post assets

The bounded catalog is a constraint on *variety*, and the product may
legitimately want "attach any animation you like to your post". That is safe —
after a tap, where exactly one is on screen:

```proto
message MapPostCard {
  // ... existing ...
  string animated_icon_url = N;  // free-form sheet or APNG; Focus path ONLY
}
```

The split is the point: **enumerated on Radar (128 on screen), free-form on
Focus (1 on screen).** The same post can carry both — a catalog id for its
marker and a bespoke asset for its detail card.

This is also where a GIF or APNG belongs. At one asset on screen the peak
footprint measured in §4 is a non-event, the file's own frame delays are the
only clock that has to be honoured, and the client already decodes every
animated container natively.

## 6. Ask F — chat emotes (optional; the client can ship without this)

The same catalog serves Twitch-style emotes in conversations, and **`chat.v1`
already carries everything required**: `SendMessageRequest` and `MessageView`
both have `content_type` and `media_ref`, and the client has never used either
(it hardcodes `content_type = TEXT`).

The client will ship emotes on the existing contract: `body` carries `:slug:`
shortcodes and is the **source of truth**, so old clients degrade to readable
`:LUL:` text rather than breaking.

The only ask here is an additive enum value, as an optimisation:

```proto
enum ContentType {
  CONTENT_TYPE_TEXT   = 0;
  CONTENT_TYPE_MEDIA  = 1;
  CONTENT_TYPE_SYSTEM = 2;
  CONTENT_TYPE_EMOTE  = 3;  // ← additive
}
```

with `media_ref` carrying the resolved ids (comma-separated, ≤12 per message),
so the server has a machine-readable signal for push previews, moderation and
analytics without parsing message text. **Not a blocker for the client.**

## 7. Payload cost

`icon_id` is ~3 bytes per pin — at a 200-pin Top-K viewport, **~600 bytes per
pan response**, against a `thumbnail_url` already carried on every media pin.
It is the cheapest field proposed for `RadarPin` by an order of magnitude, and
deliberately so: it is on the highest-frequency path in the app.

The catalog is fetched once per version. A 200-icon catalog at ≤512 KB per
sheet is ≤100 MB of CDN objects, downloaded lazily and per-icon — the client
only fetches sheets for ids it actually sees.

## 8. Amendment required to an existing client guarantee

`dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md`, under **"Client contract
(what we guarantee)"**, currently states:

> At most 3 pins animate concurrently
> (`MapVideoPlaybackCoordinator(maxConcurrent: 3)`); the rest render the still
> `thumbnail_url`.

128 always-animating icons void that sentence in a document already handed to
the backend team. It must be amended in the same change, to say explicitly that
the 3-concurrent cap continues to govern **video previews** — which decode per
frame, hold a hardware decode session each, and are a genuinely different cost
class — while **icons are uncapped, because every instance shares one resident
texture and costs a rect change**.

## 9. Until it ships

The client carries `MapPin.animatedIconID`, `nil` in production, populated in
DEBUG mock mode by the same decorator seam `MapPin.authorAvatarURL` and
`MapPlace` already use (`MapsFeatureBuilder`, gated on `pin.isText`). Sprite
sheets are baked from the app's existing bundled animation assets. The
production build is unchanged, and the day `icon_id` lands the only change is a
field mapping in `GeoDiscoveryRepository`.

This mirrors exactly how `author_avatar_url` and semantic places are already
handled, so the marker, its fallback and the hero transition are all built and
testable before the backend moves.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
