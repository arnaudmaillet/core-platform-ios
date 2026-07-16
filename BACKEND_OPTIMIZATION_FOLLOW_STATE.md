# Backend optimization: viewer-relative follow state in content payloads

**Requested by:** iOS client team
**Area:** `timeline.v1`, `search.v1`, `profile.v1`, `social_graph.v1`
**Type:** API shape optimization (latency / UX)
**Related:** `dev/BACKEND_GAPS.md` §7 (counter.v1 profile projections) — candidate to append as §11.

## Problem

No read payload in the content plane carries the **viewer's relationship to the
author**. `timeline.v1` entries, `search.v1` profile hits, and
`profile.v1.GetProfileById` all return author/profile identity only; the sole
source of follow state is a separate, per-profile round trip:

```
social_graph.v1.SocialGraphService/GetRelationStatus(actor_id, target_id)
```

### Client impact

1. **Navigation-chrome flicker on profile push.** The iOS profile screen is an
   immersive surface whose primary call to action (Follow / Following / Edit
   Profile) lives in the navigation bar and must be composed **before** the
   push animation starts (UIKit composes bar chrome with the transition;
   late-arriving items pop in after it). The client now pre-seeds the screen
   with a synchronous `ProfileIdentityStub` (handle, display name,
   `is_following?`) carried on the route from the originating cell — but no
   origin can populate `is_following` today, because no payload it renders
   contains it.
2. **Client-side guesswork.** In the absence of data, the client renders a
   statistical-prior default ("Follow") from frame 1 and cross-fades to
   "Following"/"Edit Profile" if the relationship read disagrees. This is
   cosmetically smooth but is still a *wrong-then-corrected* state for every
   profile the viewer already follows — exactly the users with the strongest
   relationship to the surface.
3. **One extra round trip per profile view**, serialized behind the push, on
   the hottest navigation path in the app (feed cell → author profile).

## Proposal

### A. Denormalize viewer context onto read models (preferred)

Add an optional, viewer-relative block to author-bearing read payloads,
resolved server-side from the authenticated caller:

```proto
// shared, e.g. common.v1
message ViewerContext {
  RelationStatus relation = 1;   // NONE | FOLLOWING | FOLLOWED_BY | MUTUAL | SELF
}

// timeline.v1 — on the entry's author summary
message AuthorSummary {
  // ...existing identity fields...
  ViewerContext viewer_context = 10;
}

// search.v1 — on ProfileHit; profile.v1 — on ProfileView
```

Notes:

- `SELF` matters: it lets clients render "Edit Profile" instead of a follow
  CTA with zero extra information.
- Eventual consistency is fine. The client treats this as a *seed* and still
  reconciles against `GetRelationStatus` (or a future push channel); a
  seconds-stale value only shortens the correction window that exists today
  in 100% of cases.
- The fan-out cost is one edge lookup per distinct author per page (timeline
  pages have ≤ ~10 distinct authors; search ≤ page size). A per-request
  memoized batch against the social-graph store keeps this O(distinct
  authors), not O(entries).

### B. Batch relationship endpoint (cheaper, complementary)

If touching the content-plane protos is too invasive for now:

```proto
// social_graph.v1
rpc BatchGetRelationStatus(BatchGetRelationStatusRequest)
    returns (BatchGetRelationStatusResponse);

message BatchGetRelationStatusRequest {
  string actor_id = 1;
  repeated string target_ids = 2;   // bounded, e.g. ≤ 100
}
```

The client would hydrate relationship state for all on-screen authors in one
round trip at page load and carry it on the route stub. This removes the
serialized-behind-the-push read but, unlike (A), still costs a request and
leaves a window on the very first page render.

Doing both is coherent: (A) seeds, (B) serves bulk reconciliation.

## Acceptance criteria

- Timeline entries, search profile hits, and profile views expose the
  viewer's relation (including `SELF`) when the request is authenticated;
  field absent/UNSPECIFIED for anonymous calls.
- Values reflect the social-graph store with bounded staleness (seconds).
- Contract lands in the pinned buf module (`buf.build/core-platform/contracts`)
  so the iOS repo can regenerate — see the protobuf-pinning note in
  `dev/BACKEND_GAPS.md`.

## Client status (for reference)

Shipped mitigations, all of which remain useful after the backend change:
route-carried identity stub (`ProfileIdentityStub`, `is_following` optional and
currently always nil), frame-1 default CTA with in-place cross-fade on
correction, transition-coordinator-bound bar updates, and a skeleton-capsule
fallback. Once `viewer_context` exists, feed/search origins populate the stub's
`is_following` and the wrong-then-corrected window disappears entirely.
