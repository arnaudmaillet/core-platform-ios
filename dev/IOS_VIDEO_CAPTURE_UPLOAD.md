# iOS task — Video capture + upload (compose)

Status: **P1 delivered 2026-09-15 (mock mode); P2 blocked on the backend**.
Drafted 2026-07-08.

The **playback** side of video is done (snap feed, PRs #19–#20). This is the
**authoring** side: letting a user add a video to a post. It's the one iOS
follow-up called out in `PHASE3_VIDEO_BACKEND.md` §7. Part of it is buildable and
testable against the mock today; the rest is gated on the Phase 3 backend.

---

## 0. How compose works today (image-only)

`Upload` feature → `PostComposer.publish(image: PickedImage?, caption:)`:

```
encode(UIImage) → IssueUploadTicket(kind:.postImage) → upload(Data) →
CommitUpload → resolveDeliveryURL (poll 6×1s) → CreatePost(kind:.carousel) →
PublishPost → optimistic insert via ComposedPostChannel
              (seeds ImagePipeline with the picked image so it renders instantly)
```

Three things here **do not translate to video** and drive the design:

1. **`resolveDeliveryURL` polls synchronously (6×1s) for a rendition URL, then
   `CreatePost` with that `cdn_url`.** Video transcode takes seconds-to-minutes
   — the client must **not** block publish on it.
2. **`Post_V1_MediaAttachmentInput` has `cdn_url` but no `asset_id`.** A post can
   only reference a *resolved URL*, which for video doesn't exist yet at publish
   time.
3. **`MediaUploadTransport.upload(_ data: Data, …)` is in-memory.** A 60 s 1080p
   clip is tens-to-hundreds of MB — must stream from disk.

---

## 1. Key design decisions

- **Publish references the asset, not a URL.** Video: `CreatePost` carries the
  `asset_id`; the post publishes immediately and becomes playable once the asset
  reaches `READY` (backend resolves delivery at read time). **Drop the
  synchronous `resolveDeliveryURL` for video.**
  → **Contract dependency:** add `asset_id` to `post.v1.MediaAttachmentInput`
  (and let the read side resolve it). *This must be added to
  `PHASE3_VIDEO_BACKEND.md`.*
- **Optimistic local playback.** Seed the optimistic `FeedEntry`'s attachment
  `url` with the **picked local file URL** — `PassthroughVideoSource` plays a
  file URL, so the author's own clip plays instantly from disk (mirrors the
  image optimistic-seed). The feed swaps to the CDN URL on the next refresh.
- **Poster frame.** Generate one with `AVAssetImageGenerator` for
  `thumbnail_url` and to show before the first frame / while an asset is still
  `PROCESSING` (for other viewers).
- **Stream large uploads from disk**, not through memory.

---

## 2. Work items

### A. Media model + picker (`Upload`)
- Add `PickedVideo` (local file `URL`, `duration`, `pixelWidth/Height`,
  `mimeType`) alongside `PickedImage`; introduce `enum ComposeMedia { case
  image(PickedImage); case video(PickedVideo) }`.
- `ComposeViewController`: `PHPickerFilter.videos` (library, **no permission**) →
  copy the picked item to a temp file URL; add a Photo/Video selector and a
  video preview (an inline `VideoRenderView` from `MediaPlayback`, or a simple
  `AVPlayerViewController` preview).

### B. Video export/normalize (`MediaCore` or `MediaPlayback`)
- `VideoExporter` (`AVAssetExportSession`, ~1080p preset) → normalized MP4 file
  URL + metadata (`duration`, dims, `sha256`, `byteSize`). Optional client-side
  compression to cap upload bytes and normalize odd source codecs (the backend
  transcodes anyway, so this is about upload size, not final format).
- Enforce max **duration** and **size** at capture (values from
  `PHASE3_VIDEO_BACKEND.md` §6 open questions).

### C. Upload transport (`MediaCore`)
- Extend `MediaUploadTransport` with a **file-based** variant
  (`upload(fileURL:using:)`) using `URLSession.uploadTask(with:fromFile:)` on the
  existing background session. Keep the in-memory path for images.

### D. `PostComposer` video path
- Refactor `publish(image:caption:)` → `publish(media: ComposeMedia?, caption:)`
  branching on media kind.
- Video branch: `export → IssueUploadTicket(kind:.postVideo, mime:"video/mp4",
  size, sha256) → upload(fileURL:) → CommitUpload → CreatePost(referencing
  asset_id) → PublishPost`. **No synchronous resolve.**
- Optimistic `FeedEntry`: attachment `mimeType:"video/mp4"`, `url:` = local file
  URL, `thumbnailURL:` = local poster → plays locally at once.

### E. Snap cell "processing" state (small, `Feed`)
- When a video attachment has **no playable URL yet** (a `PROCESSING` asset, seen
  by *other* viewers before `READY`), show the poster instead of black. Moot for
  the author (local file plays), needed for everyone else until the backend
  resolves the URL.

### F. Tests + mock
- `VideoExporter` produces a valid, playable MP4 + correct metadata (like the
  existing `PlaceholderVideoFetcher` asset test).
- `PostComposer` video path: `IssueUploadTicket` has `kind:.postVideo` +
  `video/mp4`; `CreatePost` carries the `asset_id`; optimistic entry has a video
  MIME + local URL. Drive with the mock media/authoring services.
- Mock: `MockMediaService` accepts `postVideo`; `MockPostAuthoringService`
  accepts `asset_id`; add a mock export/poster path.

---

## 3. Capture (camera) — follow-on

Library pick (§2.A) needs no permissions and is the MVP. Recording:
- `UIImagePickerController(sourceType:.camera, mediaTypes:[movie])` for a quick
  path, or a custom `AVCaptureSession` recorder for a TikTok-style capture UI.
- **Info.plist:** `NSCameraUsageDescription` + `NSMicrophoneUsageDescription`
  (both required for capture; PHPicker library selection needs neither).

---

## 4. Dependencies & coordination

**Backend (add to `PHASE3_VIDEO_BACKEND.md`):**
- `post.v1.MediaAttachmentInput.asset_id` (NEW) — reference an asset before its
  delivery URL exists.
- `media.v1.MediaKind.MEDIA_KIND_POST_VIDEO` (already in that spec).
- Read-side delivery resolution + a poster/"processing" state until `READY`.
- Max duration/size limits (client enforces at capture).

**Contract (may need):** a `post.v1.PostKind` video value, or reuse `.carousel`
(the feed routes on MIME, not `PostKind`, so reuse works — confirm with backend).

---

## 5. Phasing

- **P1 — DONE (2026-09-15).** `PickedVideo`, `VideoExporter`, the file-based
  transport and `PostComposer`'s video path were built earlier and were already
  green; what was missing to the very end was one hop — `MediaLibraryReading`
  vended `UIImage` only, so the finalisation screen had nothing to hand the
  composer and `post()` filtered videos out with `where !item.isVideo`.
  The seam now has `videoFile(for:) async -> URL?` (a file URL, **not** an
  `AVAsset`: `AVAsset` is not `Sendable` and `PHImageManager` answers on an
  arbitrary queue — the full table is on the protocol), `PhotosMediaLibrary`
  materialises one via `requestAVAsset` or a passthrough export, and
  `DebugMediaLibrary` synthesises a real H.264 clip so CI and the simulator can
  drive the whole path. A video also uploads a **poster still** for
  `thumbnail_url`; without it the thumbnail was the .mp4, which is a black feed
  rather than a missing picture (see `BACKEND_GAPS.md` §23).

  ⚠️ **AND CI NOW RUNS THE WHOLE CREATION PATH FOR VIDEO**, which it never
  could before: `VideoPublishEndToEndTests` drives the real `DebugMediaLibrary`
  (synthesising genuine H.264, its tiles drawn from the clip's own first frame
  so the grid shows what the post will carry) through the real
  `NewPostViewController` into a real `PostComposer` against `MockBFF`. Only
  the transport is fake, and it is fake exactly as the app's own mock mode is.
  "There is no photo library on a runner" was the reason the video path went
  four screens' worth of work without anyone noticing `where !item.isVideo`;
  it is no longer a reason.

  **`-rich-media` puts REAL encodes behind the picker** — Big Buck Bunny and the
  Sintel trailer, from `MockMediaFixtures`' verified catalogue, downloaded once
  and cached by `PlaceholderVideoFetcher`. Opt-in, and deliberately the same
  flag the fixtures themselves obey: the default mock mode is offline, and the
  unit suite and CI must stay that way. Real encodes immediately earned their
  keep — they are what showed that `VideoExporter.posterImage` sampled at
  exactly t=0, so any clip that fades in (Sintel does) published a **black**
  `thumbnail_url`. It now samples a tenth of the way in, capped at a second,
  with the tolerance pinned to "at or after" so a short clip's keyframe cannot
  drag it back to zero.
- **P2 — needs backend:** `asset_id` on `CreatePost`, the "processing" poster
  state, real fleet `upload → transcode → play`.
- **P3:** camera capture UI + permissions.
- **P4:** trim / edit / cover-frame selection — **including crop and straighten,
  which photos already have.** `MediaEditorViewController` offers a "Crop" mode
  with an interactive box, a straightening dial, quarter turns and a mirror; on a
  video page it draws a notice instead.

  **In-editor PLAYBACK landed 2026-09-15** and is not part of what remains: the
  settled page plays its clip through an Upload-owned
  `VideoPlaybackController(poolSize: 1, capacity: 1)` behind a
  `MediaPreviewPlaying` seam — never the feed's pool, because a pool owned by the
  screen dies with the screen. One page plays at a time; the fill/fit choice
  drives `VideoRenderView.videoGravity`, which had been hardcoded to
  `.resizeAspectFill` and is now the caller's to set. What P4 still needs is
  EDITING, which is a different problem: `MediaCrop.apply` and `MediaFilter` are
  `UIImage`-to-`UIImage` by signature.

  **The library seam is no longer what blocks this** — P1 closed it. What blocks
  it now is that the edit types are `UIImage`-shaped: `MediaCrop.apply` and
  `MediaFilter` are `UIImage`-to-`UIImage` by signature, so the editor can bake a
  crop into a video's POSTER frame and nothing else.

  Three things to settle before writing any of it:

  1. ⚠️ **`AVMutableVideoComposition` is DEPRECATED in iOS 26.0** — this repo's
     deployment target — in favour of `AVVideoComposition.Configuration`
     (`AVVideoComposition.h:263`; same for the mutable Instruction and
     LayerInstruction at `:558` / `:654`). An earlier draft of this section
     prescribed it. Do not.
  2. ⚠️ **CI FILTERS OR AN ARBITRARY OUTPUT RATIO — NOT BOTH. MEASURED
     2026-09-15, NOT INFERRED** (`VideoCompositionRouteTests`, MediaPlayback).
     On a 160x120 source:

     | route | renderSize | exported |
     |---|---|---|
     | `AVVideoComposition(applyingFiltersTo:applier:)`, applier returning a **120x120** image | 160x120 | **160x120** |
     | `AVVideoComposition.Configuration` with `renderSize = 120x120` | 120x120 | — (no filter slot) |

     So **a CI applier cannot crop; it can only letterbox.** The square came back
     placed inside the source's rectangle. "Cut this clip to that rectangle" is
     not expressible through the filter route at all, and a design that assumed
     otherwise would publish bars baked into the pixels.

     The modern spelling is `init(applyingFiltersTo:applier:)` — the
     `completionHandler:` variant is itself deprecated now. `Configuration`
     exposes `renderSize`, `instructions` and `customVideoCompositorClass`, and
     no Core Image slot.

     **Three ways out, and the choice is still open:** two export passes (filter,
     then crop — simple, one extra encode); a custom `AVVideoCompositing` (one
     pass, most work, most control); or express the crop as an
     `AVMutableVideoCompositionLayerInstruction` transform under `Configuration`
     and do the look some other way. Pick when the trim slice lands, not before —
     trim needs none of this.
  3. **Trim needs no composition at all** — `AVAssetExportSession.timeRange` —
     so it can ship regardless of how (2) lands, and it is the most-used video
     edit. `VideoExporter.export` takes a `URL` today and would need to accept a
     plan (time range, and a composition BUILDER rather than a composition: a
     composition must be built where the asset lives, and `AVComposition` is not
     `Sendable` while `AVVideoComposition` is only `@unchecked` so).

  When crop does land, `MediaCrop.rect` is fractions of the **turned bounding
  box**, which is invisible at angle zero where nearly every existing test lives
  — so a video path that reads it differently from the photo path will agree on
  every test and disagree on every real rotation. One renderer, shared.

P1 delivered exactly what it promised: "pick a video → it publishes and plays
(locally)", end to end in mock mode, de-risking everything before the backend
lands — the same build-ahead pattern used for snap-feed Phases 1–2. Everything
it cannot do against a real fleet is enumerated in `BACKEND_GAPS.md` §23.
