# A moving version of a post's media, inside its map marker — options

**Status:** exploration. No code written. Branch `claude/map-marker-media-preview`.

**Scope:** a media post's own content, moving on its map marker (annotation AND
cluster). This is NOT the animated-icon feature — that is text-only posts and an
`icon_id`, and it shipped (`BACKEND_ANIMATED_PIN_ICONS.md`).

---

## 0. The surprise: most of this is already wired

`MediaPlayback` is a complete engine — a bounded player pool, one-decoder→N-surface
rendering, one process-wide `CADisplayLink`, still capture — production default
since 2026-08-02, with 9 test files. And the map is already plumbed into it:

| piece | state |
|---|---|
| `PinCardView.videoRenderView` | built, layered above the cover and below the ring |
| selection → playback | built — `MapVideoPlaybackCoordinator`, ranks visible video pins by distance to centre, **cap 3** |
| visibility gating | built — tab-hidden / feed-pushed / backgrounded |
| hero flight adopting the LIVE surface | built |
| `MapPin.previewVideoURL` | built, and **always `nil` in production** |

The blocker is the wire: `RadarPin` carries four fields, none of them a media
kind or a preview URL, so `kind(for:)` classifies every covered pin as `.photo`
and `.video` cannot occur. `GeoDiscoveryRepository.previewVideoURL` returns nil
unconditionally outside DEBUG.

### ⚠️ But "already works" is not verified, and one attempt says otherwise

Launched `-rich-media -maps-force-video` on the simulator: the rich-media
fixtures load (real photographs on markers) and **nothing moves** — 0.31 mean
per-pixel difference across a second, against 3.3–16.2 for a marker that is
genuinely animating. One marker rendered as an empty white square where a video
surface would be.

Two known reasons, either sufficient:

- `-maps-force-video` hands the **thumbnail URL** to the player as if it were a
  clip. For a rich-media fixture that is a still image.
- The synthetic `mock://video` catalogue decodes to **black** through
  `AVPlayerItemVideoOutput` — recorded in `MockMediaFixturesTests`.

So the correct summary is: **the path is built and has never been exercised
end-to-end against a real clip on this screen.** Any plan that treats it as
proven is taking an unmeasured risk.

---

## 1. Options, ruled out by mechanism

| # | option | why it lives or dies |
|---|---|---|
| 1 | **`PREVIEW_LOOP` MP4, cap 3** — the incumbent | One decode session per playing marker, ~0 resident texture. **27.7 KB for a 2 s 132px H.264 loop** against a ≤300 KB negotiated ceiling. Nothing near a wall at 3. |
| 2 | **Server-baked preview SHEET** + `contentsRect` keyframes | Zero decode sessions, zero per-frame app CPU, no concurrency limit. Reuses `AnimatedIconSheet` verbatim. Dies on memory: **2.65 MB/clip** at 56pt/@3x/24 frames, **50.4 MB at 19 markers against a 24 MB cache**. |
| 3 | Client-baked sheet (`AVAssetReader` on device) | Each bake holds a decode session, and **a pan IS first sighting** — it converts a bounded steady-state cost into a burst on the most common interaction. |
| 4 | Decomposed still + affine track | **Mechanically impossible.** The icon win needs motion that is a rigid mark under scale/rotate/fade. A post's media is pixels changing; there is no track to send. |
| 5 | One `AVPlayer` per marker at N≈20 | One hardware decode session each against a single-digit device budget, and the arbiter **starves a session already running** rather than refusing the new one. Pin 7 breaks pin 2, with no error at pin 2. |
| 6 | Animated container per pin (WebP/HEICS/APNG/GIF) | N concurrent ImageIO decodes peaking on a pan; measured 63–81 MB at 19 markers, 428–546 MB at 128. Plus: `CGImageSourceCreateThumbnailAtIndex` **never returns** on HEIC under concurrent load on the iOS 26 simulator; per-file delays fragment the shared clock (10 fps presented for 30 asked); GIF cannot express 30 or 60 fps at all. |
| 7 | One `CAMetalLayer` over the map, N quads | Fails **architecturally**, not computationally: a Metal quad is not an annotation view — no hit test, no lifecycle, and no view for the hero flight to adopt. Buys nothing over #2, which already costs zero app CPU per frame. |

---

## 2. The recommendation

**Primary: finish the `PREVIEW_LOOP` path at cap 3. Do not build a second
mechanism.** The remaining client work is small and named:

- pass `scope: postID.rawValue` and a `peakBitRate` at `MapVideoPlaybackCoordinator.swift:95`
  — it passes **neither** today, and nil is not "no scope": two markers on one
  URL join a single player
- widen `Candidate.view` past `MapAnnotationView` so a **cluster face** can play
  (representatives are kind-neutral, so a video post can lead a cluster and
  silently never play)
- re-rank on region-change settle, not only on annotation-set change
- add `MapVideoPlaybackCoordinatorTests` — there is no test file for it
- one field mapping the day the wire lands

**Fallback: a server-baked `PREVIEW_SHEET` rendition, if the requirement is
"every media marker moves."** Take it only with the arithmetic on the table:
either the cache budget roughly doubles, or the cell drops to ~117px and the
marker gets visibly softer on photographic content. Both are product decisions.

**The two answer different sentences.** #1 is "the three markers you are looking
at move". #2 is "the map moves". Pick the sentence before the mechanism.

---

## 3. What the backend would have to produce

`PREVIEW_LOOP`: progressive MP4, **muted, no audio track**, 2–3 s, short edge
≤480px, ≤300 KB, seamlessly loopable, faststart — denormalised into the pin
projection at index time, because the pan path must not hydrate. ~100 bytes/pin
on the wire.

**It would be the pipeline's FIRST video rendition, not an increment.** Rendition
kinds today are image-only (`ORIGINAL | THUMBNAIL | SMALL | MEDIUM | LARGE`),
`media.v1.MediaKind` has no `VIDEO`, and nothing is produced at all — committed
assets sit in `PENDING` forever (`dev/BACKEND_GAPS.md` §2).

⚠️ **The field-number ledger is still blocking**, and this proposal is the fourth
claimant on 5–6. Renumbering is free today and stops being free the moment any
one of the four lands.

---

## 4. What to measure first

**The cheapest experiment that would falsify the primary path is a GPU
measurement of three masked, per-frame-changing 56pt markers, on hardware.**

`PinCardView` puts a 12pt corner radius and `clipsToBounds` over a surface whose
contents change 30 times a second. The icon face escapes exactly this by taking
`cornerRadius: 0` — which the icon contract calls the largest cost that feature
could have had. Nobody has checked it for the media face, because at 3 instances
nobody had to.

⚠️ **Fix the fixture first or the measurement is 3× optimistic:** every video pin
currently carries the identical URL and the coordinator passes no scope, so
"three concurrent pins" is **one decoder**. And do not fall back to the synthetic
catalogue — it decodes to black, so every visual check judges a black source.

**Kill criterion:** three genuinely distinct decode sessions with masked surfaces
pushing the map below ~55 fps presented under pan, or showing an offscreen pass
per marker per frame. Then the mask has to go — a square media marker — before
anything else is discussed.

**Second experiment, ~1 hour, no backend and no device:** bake one sheet from a
real clip at 170px/24 frames, load 19 through `AnimatedIconCatalog`, read
`residentBytes`. It will evict. That is not a surprise — it is a number to hand
the product owner, and it settles the sheet option before anyone writes a bake.

---

## 5. Open questions

1. **Is the ask "three move" or "all move"?** The shipped guarantee is at most 3;
   the icon feature's requirement was unqualified. Different mechanisms,
   different backends.
2. **24 MB or 48 MB?** `AnimatedIconCatalog` defaults to **24**; the icon
   contract says **48** in four load-bearing sentences. Every eviction projection
   in that document is 2× optimistic against shipped code. Resolve before any
   sheet sizing is trusted.
3. **Every number here is simulator-bound.** The decode-session ceiling is a
   device property the simulator does not model — it will happily run twenty
   players and report success. So is the offscreen cost.
4. **Does the shipped path actually play?** See §0. It has never been seen
   working end to end.
