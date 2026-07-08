# Phase 3 — Video pipeline: backend requirements

Status: **not started (backend-owned)**. Drafted 2026-07-08.

The iOS snap feed (Phases 1–2, merged to `develop`) is complete and already
plays video — against *synthesized* clips in mock mode. This document is the
backend work required to make it play **real** video on the fleet. There is no
further iOS work gated behind most of this: when the pipeline emits a
video-classified asset with a client-reachable playable URL, the existing app
plays it unchanged.

Extends the existing gaps `BACKEND_GAPS.md` §2 (media worker not running) and
§3 (presigned URLs use the Docker-internal host) to cover video.

---

## 0. What the client already does (the integration target)

Know these so the contract/worker output lands exactly where the app reads it:

- **MIME-based routing.** The client classifies an attachment as video purely
  from its MIME type: `MediaKind(mimeType:)` routes `video/*` (and the HLS type
  `application/vnd.apple.mpegurl`) to the player; everything else to the image
  pipeline. So the *minimum* to make a post play is: its
  `post.v1.MediaAttachmentView.mime_type` is a video/HLS type and its `cdn_url`
  is a playable URL.
- **Playback is a raw `AVPlayer` open.** `MediaPlayback.PassthroughVideoSource`
  hands the delivery URL straight to `AVPlayer` (fleet mode). That URL must be a
  progressive **MP4** (HTTP range requests) or an **HLS `.m3u8`** manifest, over
  HTTPS, publicly reachable, with correct `Content-Type`.
- **Duration is already in the contract.** `post.v1.MediaAttachmentView` has
  `duration_seconds` (field 6). Populate it — the client will surface duration /
  a scrubber without any contract change.
- **The client cannot rewrite URLs inside a manifest.** The fleet host-rewrite
  workaround (`minio:9000` → `localhost:9000`, `BACKEND_GAPS.md` §3) only fixes
  the *one* top-level URL the client fetches. An HLS manifest's segment URLs are
  fetched by AVPlayer itself — the backend MUST emit reachable hosts for the
  manifest **and every segment**.

---

## 1. Contract changes — `media.v1` (all additive)

No new RPCs. `IssueUploadTicket → CommitUpload → ResolveDelivery /
BatchResolveDelivery → Reprocess` already model the whole lifecycle, and
`Asset`/`Rendition`/`DeliveredRendition` already carry
`mime_type`/`width`/`height`/`byte_size`.

1. **`MediaKind`: add `MEDIA_KIND_POST_VIDEO = 3`.** The generated enum comment
   already reserves this ("planned fast-follow phase … added as a new, additive
   enum value"). `IssueUploadTicketRequest.kind` accepts it. Image values
   unchanged.
2. **`RenditionKind`: add video/streaming kinds** (current values are image
   sizes only — `ORIGINAL/THUMBNAIL/SMALL/MEDIUM/LARGE`):
   - `MEDIA_RENDITION_KIND_HLS = 6` — the adaptive `.m3u8` manifest (primary).
   - `MEDIA_RENDITION_KIND_POSTER = 7` — a JPEG poster frame (feed thumbnail).
   - *(optional)* `MEDIA_RENDITION_KIND_MP4_720 = 8` — a progressive fallback.
3. **Add `duration_ms` (uint32) to `media.v1.Asset` and `media.v1.Rendition`.**
   Optional but recommended so duration is available without joining post.v1.
4. `ResolveDeliveryRequest.preferred` = `MEDIA_RENDITION_KIND_HLS` returns the
   manifest; poster is resolvable separately for the feed cell thumbnail.

---

## 2. Transcode worker (fixes §2 for video)

Today committed assets sit in `MEDIA_ASSET_STATE_PENDING` forever (no worker).
For `MEDIA_KIND_POST_VIDEO`:

- **Trigger:** on `CommitUpload` of a video asset (`UPLOADED` → `PROCESSING`).
- **Validate/probe:** container, codec, duration, dimensions, bitrate. Enforce
  max duration and max size (see open questions). Reject → `FAILED`; AV-scan /
  moderation failure → `QUARANTINED`. (`AssetState` already has all these.)
- **Transcode to an ABR HLS ladder.** Recommended: H.264 + AAC, fMP4 or TS
  segments, 2–6 s segments, rungs ~1080p/720p/480p/360p. Generate a **poster**
  JPEG (first clean frame or a configurable timestamp).
- **Persist renditions** (manifest object + segments + poster) to the object
  store; write `Rendition` rows: `kind` (HLS / POSTER), `url`, `mime_type`,
  `width`/`height`, `byte_size`, `duration_ms`.
- **State:** success → `READY`; any failure → `FAILED` with a reason surfaced via
  `GetAsset`. Must be **idempotent + resumable**; `Reprocess` re-runs it.

---

## 3. Delivery (fixes §3 for video)

`ResolveDelivery` / `BatchResolveDelivery` for a `READY` video asset must return
`DeliveredRendition`(s) whose `url` is:

- **Client-reachable** — the published/CDN host, never `minio:9000`. This must
  apply to the manifest **and its segments** (the client can't rewrite in-manifest
  URLs — see §0).
- **HTTPS, correct `Content-Type`:** `application/vnd.apple.mpegurl` (manifest),
  `video/mp4` / `video/MP2T` (segments), `image/jpeg` (poster).
- **Range-capable** for progressive MP4; standard segment GETs for HLS.
- **Expiry-safe if signed:** set `url_expires_at` comfortably beyond a play
  session, and ensure a signed manifest yields **valid segment URLs** — either
  per-segment presigning or a signed cookie/token that AVPlayer carries. (AVPlayer
  forwards cookies/headers to segment requests; confirm the chosen scheme works
  with that.)

---

## 4. Feed integration — `post.v1`

The snap feed reads `post.v1.PostView.attachments[].{mime_type, cdn_url,
thumbnail_url, duration_seconds, width, height}` directly (via `GetPost`
hydration). For a video attachment, `GetPost` must return:

- `mime_type` = the video/HLS MIME type,
- `cdn_url` = the **resolved, ready-to-play** manifest URL,
- `thumbnail_url` = the poster URL,
- `duration_seconds` > 0, plus `width`/`height`.

**Recommendation:** have the BFF *pre-resolve* the playable URL during feed
hydration rather than making the client call `ResolveDelivery` per cell — a
per-cell round trip adds latency to every page. (Same batched-hydration argument
as the existing note in `FeedRepository`.)

---

## 4a. Authoring — reference assets by id (`post.v1` write path)

Required by the iOS compose/upload path (`IOS_VIDEO_CAPTURE_UPLOAD.md`). Video
transcode is async and slow, so the client **cannot** resolve a delivery URL
before publishing (the image path does — it polls `ResolveDelivery`, then
`CreatePost` with the `cdn_url`). A video post must be publishable the moment
the bytes are committed, and become playable once the asset reaches `READY`.

- **Add `asset_id` (string) to `post.v1.MediaAttachmentInput`.** For video,
  `CreatePost` references the asset by id (delivery URL unknown at publish time)
  rather than by `cdn_url`. Keep `cdn_url` for the image path (backward
  compatible; both fields optional, `asset_id` wins when set).
- The **read side** (`GetPost` / feed hydration, §4) resolves the asset's
  delivery for a referenced `asset_id` once `READY`, and returns the poster +
  a "processing" signal while it is still `PROCESSING` (so the feed can show the
  poster instead of a broken/empty player).
- No change to `PublishPost`.

## 5. Acceptance criteria (definition of done)

1. `GetFollowingFeed → GetPost` for a video post returns `mime_type: video/*`
   (or HLS), a reachable `cdn_url`, a poster `thumbnail_url`, and
   `duration_seconds > 0`.
2. `curl` from a non-Docker host: the manifest **and** its first segment return
   `200` with correct `Content-Type`.
3. Asset lifecycle is observable via `GetAsset`:
   `PENDING → UPLOADED → PROCESSING → READY` (or `FAILED`/`QUARANTINED`) — no
   more indefinite `PENDING`.
4. The iOS snap feed in **fleet mode** (`-use-local-fleet -snap-feed`) plays the
   real clip end-to-end (playback rate 1, currentTime advances), with the poster
   shown before the first frame.

---

## 6. Open questions for the backend team

- Max video **duration** and **size** limits? (The client should also enforce at
  capture time — feeds into the compose/upload path, a later iOS task.)
- HLS **signing** strategy: per-segment presign vs. signed cookie/token?
- **CDN** in front of the object store, or direct presigned object-store URLs?
- **Moderation / AV-scan** gate before `READY`? (`QUARANTINED` exists for this.)
- **Poster** frame timestamp: first frame vs. a fixed offset?
- Upload path: does `IssueUploadTicket` for video need multipart/resumable
  upload (large files), or is a single presigned `PUT` sufficient?

---

## 7. Client seams this plugs into (no iOS change needed for playback)

- `MediaPlayback.PassthroughVideoSource` — opens the delivery URL in `AVPlayer`.
- `MediaCore.MediaKind(mimeType:)` — `video/*` → the player path.
- `Feed.FeedItemDisplayModel.mediaKind` — set from the attachment MIME type.

Follow-up iOS work (separate from playback, not blocking): a video **capture +
upload** path in the compose flow, and surfacing `duration_seconds` / a scrubber.
