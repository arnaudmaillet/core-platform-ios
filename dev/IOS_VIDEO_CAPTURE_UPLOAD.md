# iOS task — Video capture + upload (compose)

Status: **not started (iOS-owned)**. Drafted 2026-07-08.

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

- **P1 — mockable now (no backend):** `PickedVideo` + PHPicker video +
  `VideoExporter` + file-based transport + `PostComposer` video path against the
  mock; optimistic **local** playback in the snap feed. Fully testable in CI.
- **P2 — needs backend:** `asset_id` on `CreatePost`, the "processing" poster
  state, real fleet `upload → transcode → play`.
- **P3:** camera capture UI + permissions.
- **P4:** trim / edit / cover-frame selection.

P1 delivers a working "pick a video → it publishes and plays (locally)" flow end
to end in mock mode, de-risking everything before the backend lands — the same
build-ahead pattern used for snap-feed Phases 1–2.
