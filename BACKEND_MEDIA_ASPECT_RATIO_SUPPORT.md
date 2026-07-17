# Backend: media aspect-ratio metadata for mosaic layouts

**Requested by:** iOS client team
**Area:** `post.v1`, `search.v1` (and the media pipeline that populates them)
**Type:** API data completeness (layout / UX)
**Related:** `BACKEND_OPTIMIZATION_FOLLOW_STATE.md` (same "payload lacks what the
surface renders" family), `dev/BACKEND_GAPS.md` §media pipeline.

## Problem

The profile gallery's Media page now renders an **asymmetric mosaic**: a
repeating compositional pattern mixing 1×1 squares with 1×2 portrait and 2×1
landscape blocks. Today the pattern is **positional** — an item's shape is
decided by its slot in the repeating pattern, not by the media itself. That
means a portrait photo can land in a landscape slot (and vice versa), and
`scaleAspectFill` crops whatever doesn't fit — sometimes the subject of the
image.

The obvious upgrade is a **metadata-driven mosaic**: place portrait assets in
portrait slots, landscape assets in landscape slots, squares in squares. The
client can do this purely from asset dimensions — but only if every payload
that feeds the grid actually carries them.

## Current contract reality

- `post.v1.MediaAttachmentView` **already has `width`/`height` fields** (plus
  `duration_seconds`). The schema is not the gap.
- What is unverified/missing:
  1. **Fleet population.** The media pipeline must reliably stamp `width`/
     `height` on every attachment at ingest/transcode time. Today the client
     cannot trust these fields on the fleet (the mock seeds them; production
     behavior is unconfirmed). If a transcode pipeline rewrites variants, the
     fields should describe the **original asset's aspect**, or at least the
     served variant's.
  2. **`post.v1.PostSummary` carries no media metadata at all** (id, kind,
     status, timestamps). Any surface that wants to lay out a mosaic *before*
     hydrating full `PostView`s — e.g. skeleton layout during load, or a
     future summaries-only fast path — has nothing to shape the grid with.
  3. **`search.v1.PostHit` carries `thumbnail_key` but no dimensions**, so
     mosaic surfaces fed by search (the gallery's Tagged source) have the same
     blind spot on their lightweight path.

## Proposal

Pick one (or both) of:

- **A. Dimensions everywhere media is referenced** — add `media_width` /
  `media_height` (or reuse the attachment message) to `PostSummary` and
  `PostHit`, and guarantee the media pipeline populates them on
  `MediaAttachmentView` at publish time. Backfill existing rows from stored
  asset metadata.
- **B. Coarse orientation enum** — if exact dimensions are costly on the
  lightweight paths, a 3-value `orientation: SQUARE | PORTRAIT | LANDSCAPE`
  on summaries/hits is sufficient for slot assignment; exact dimensions can
  remain hydration-only.

Option A is preferred: exact dimensions also unlock correct pre-layout of the
timeline rows' media previews (today a fixed 180pt height crops portrait
assets aggressively) and eliminate image-load reflow anywhere we can size
frames before pixels arrive.

## Client status / interim behavior

- The mosaic ships positional: shapes rotate through the pattern regardless of
  asset aspect. Acceptable visually, but crops are content-blind.
- The gallery hydrates full `PostView`s already, so once (1) is confirmed on
  the fleet the client can adopt aspect-aware slotting for the primary path
  with no schema change; (2)/(3) gate only the lightweight paths.
- Mock note: `MockSocialDataset` seeds varied portrait/landscape/square shapes
  on attachments, so the client work is testable offline today.
