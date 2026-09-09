# `search.v1`: the filter surface a search screen needs

**Status:** proposal. Nothing here is implemented client-side beyond `sort`,
which the contract already carries.

## Why

The iOS client has one global search screen, reached from the Maps and For You
headers. The product asks it for a filter tray with three dimensions:

1. **Order** — trending, publication date, most liked (points), most commented
2. **Publication window** — last 24h, last week, last six months, all
3. **Perimeter** — all, already seen, not seen, followed

Of those twelve entries, **two and a half** can be expressed against `search.v1`
as it stands. The tray ships with the order dimension only; the rest is this
document.

## What the contract has today

`SearchRequest` (search_v1_messages.pb.swift) carries exactly six fields:

    query, entity_types, sort, page_size, page_token, exclude_author_ids

`SearchSort` carries exactly three values — `RELEVANCE`, `RECENCY`,
`POPULARITY` — and the generated comment is explicit that POPULARITY "reads the
periodically-refreshed popularity signal, never a real-time count".

`SearchHit` projects `ProfileHit { handle, display_name, avatar_key, verified }`,
`PostHit { author_id, author_handle, thumbnail_key, created_at }` and
`HashtagHit`. A profile hit therefore carries **no date, no counts, and no
viewer state**.

## Entry by entry

| Requested | Wire field | Verdict |
|---|---|---|
| Trending | `sort = POPULARITY` | Approximate. Popularity is a refreshed signal, not "trending now" — no time window, no velocity |
| Publication date (order) | `sort = RECENCY` | **Works** |
| Most liked / points | — | No like sort exists. POPULARITY is coarse and must not be labelled as a like count |
| Most commented | — | Nothing in `search.v1`. Comment counts live in `counter.v1`, one batched read away — but only for hits that are POSTS, and only for the page the client holds |
| Last 24h / week / six months | — | No date field on `SearchRequest`. Not client-derivable for people: `ProfileHit` has no timestamp. Derivable for posts *within one page* via `PostHit.created_at`, which filters the page rather than the query — a different and wrong answer |
| Perimeter: all | default | Works by omission |
| Perimeter: followed | — | Derivable client-side with one `ListFollowing(viewer)` read and an intersection, at the cost of paging the whole follow list and filtering a page rather than the query |
| Perimeter: seen / not seen | — | **Nothing anywhere.** No service records which entities a viewer has seen, and the client keeps no such store either |
| Locations | — | `SearchEntityType` has `PROFILE`, `POST`, `HASHTAG`. There is no place/location kind, and `geo_discovery.v1` has no text search |

## What we need

Additive fields on `SearchRequest`:

    // Restrict to entities published in a window. Absent => no bound.
    google.protobuf.Timestamp published_after  = 7;
    google.protobuf.Timestamp published_before = 8;

    // Viewer-relative scope, resolved at the EDGE like exclude_author_ids is —
    // search must not index per-viewer state.
    enum SearchScope {
      SEARCH_SCOPE_UNSPECIFIED = 0;  // everything
      SEARCH_SCOPE_FOLLOWED    = 1;  // authors the viewer follows
      SEARCH_SCOPE_SEEN        = 2;
      SEARCH_SCOPE_UNSEEN      = 3;
    }
    SearchScope scope = 9;

Additive values on `SearchSort`:

    SEARCH_SORT_MOST_COMMENTED = 4;
    SEARCH_SORT_MOST_LIKED     = 5;   // distinct from POPULARITY: an actual count

And a `PLACE` entity kind, if location search is to be a thing this screen can
offer.

⚠️ **`SEEN` / `UNSEEN` needs a producer before it needs a filter.** Nothing in
the fleet records what a viewer has seen. That is a bigger question than search
— it belongs with whatever eventually owns view state — and the enum values
above are only useful once something answers them.

⚠️ **Scope belongs at the edge, not in the index.** `exclude_author_ids` already
establishes the boundary: the edge resolves the viewer's social graph and hands
search a plain id list, so per-viewer facts stay out of the shared index.
`SCOPE_FOLLOWED` should resolve the same way.
