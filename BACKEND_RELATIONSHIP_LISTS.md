# Backend: relationship-list privacy, follower removal, and edge hydration

**Requested by:** iOS client team
**Area:** `social_graph.v1`, `profile.v1`, `account.v1`
**Type:** privacy contract (13a) + missing command (13b) + API shape (13c)
**Related:** `dev/BACKEND_GAPS.md` §13 (summary), §7 (counter projections),
§12 (account-level block); `BACKEND_OPTIMIZATION_FOLLOW_STATE.md` (shares the
proposed `ViewerContext` block)

The iOS client now ships a **Followers / Following** screen, reached from the
profile header's counter row. It is built against the contracts as they stand
and works end to end. This document is what it had to work around.

Section 1 is a privacy gap and should be read on its own merits; 2 and 3 are a
missing command and a request-count problem.

---

## 1. There is no relationship-list privacy anywhere in the contracts

### What exists

```proto
// social_graph.v1
message ListFollowersRequest { string followee_id = 1; int32 limit = 2; string page_token = 3; }
message ListFollowersResponse { repeated EdgeSummary followers = 1; string next_page_token = 2; }
// ListFollowing is the same shape in the other direction.
```

No permission input, no access output, no documented refusal code. As far as
the wire is concerned, every follower list is world-readable.

We checked everywhere else a privacy flag could plausibly live:

| Surface | Finding |
|---|---|
| `profile.v1.ProfileView.visibility` | `{UNSPECIFIED, PUBLIC, PRIVATE}` — one flag for the **whole profile** |
| `profile.v1.SetVisibility` | sets that same whole-profile flag |
| `account.v1` | 22 RPCs, none of them settings or privacy |
| `chat.v1.ToggleVisibility` | conversation archiving; unrelated |
| `social_graph.v1` | follow and block edges only |

So the platform has no way to express "my profile is public but my follower
list is not", and no settings surface through which a user could set it.

### What the client does in the meantime

`RelationshipListAccess` (in `Profile/Data/ProfileRelationshipsRepository.swift`)
derives the rule the major platforms converge on, from the whole-profile flag:

| subject | viewer | result |
|---|---|---|
| any | is the subject | visible |
| `visibility != PRIVATE` | anyone | visible |
| `visibility == PRIVATE` | follows the subject | visible |
| `visibility == PRIVATE` | does not follow | **private state, no RPC issued** |

Two properties worth stating, because they are what make this safe to ship:

1. **It only ever errs toward hiding.** It can withhold a list the backend
   would have served; it can never reveal one the backend refuses.
2. **A refusal is treated as an answer.** `PERMISSION_DENIED` from either list
   RPC maps to the same private state, not to a retryable error. The day the
   fleet enforces this, the client is already correct — no client change is
   needed to adopt enforcement.

### Why it still needs fixing

The inference is a client-side approximation of a privacy boundary, and a
client is not an enforcement point. Concretely, today:

- a viewer who bypasses the app (or an older build) can read any private
  profile's follower list straight from the service;
- a PUBLIC profile cannot make its follower list private, and the client will
  show it, because there is no flag to read;
- the two lists cannot be configured independently (many users want their
  *following* list public and their *followers* list closed, or the reverse).

### Proposal

**A. Say what happened on the response.** Distinguishing "empty" from
"withheld" is the minimum, and it is what lets clients render an honest state:

```proto
// social_graph.v1
enum ListAccess {
  LIST_ACCESS_UNSPECIFIED = 0;
  ALLOWED                 = 1;
  RESTRICTED              = 2;  // list omitted by policy, not absent in fact
}

message ListFollowersResponse {
  repeated EdgeSummary followers = 1;
  string next_page_token         = 2;
  ListAccess access              = 3;
}
```

`PERMISSION_DENIED` would also be acceptable and the client already handles it;
an in-band field is preferred because it composes with pagination and doesn't
force error-path handling for an ordinary state.

**B. Make the policy expressible per surface.**

```proto
// profile.v1
enum AudienceScope {
  AUDIENCE_UNSPECIFIED = 0;
  EVERYONE             = 1;
  FOLLOWERS            = 2;
  NOBODY               = 3;
}

message ProfileView {
  // ...existing fields...
  AudienceScope follower_list_visibility  = 20;
  AudienceScope following_list_visibility = 21;
}
```

Defaulting `UNSPECIFIED` to `EVERYONE` keeps current behaviour and lets the
client drop its inference the moment the field is populated.

**C. Give the user somewhere to set it.** `account.v1` has no settings surface
at all, which blocks not just this but any future privacy work:

```proto
// account.v1
rpc GetPrivacySettings(GetPrivacySettingsRequest) returns (PrivacySettingsView);
rpc UpdatePrivacySettings(UpdatePrivacySettingsRequest) returns (CommandResponse);

message PrivacySettingsView {
  string account_id                       = 1;
  AudienceScope follower_list_visibility  = 2;
  AudienceScope following_list_visibility = 3;
  bool discoverable_by_handle             = 4;
  bool allow_messages_from_non_followers  = 5;  // the inbox's Requests partition
}
```

**Enforcement must be server-side.** Fields alone do not close the gap — the
list RPCs have to honour them for callers who aren't going through our client.

---

## 2. No `RemoveFollower` command

A user cannot drop someone from their own follower list, and the action cannot
be composed from the commands that exist:

- `Unfollow(actor_id, target_id)` is authorized **as the actor**. Removing a
  follower means causing *their* unfollow, which the viewer is not entitled to
  issue under this signature.
- `Block` then `Unblock` does sever the edge, and is deliberately **not** used:
  it also tears down the reverse edge, and it writes a moderation event for
  something that is not a moderation action.

### Proposal

```proto
// social_graph.v1
rpc RemoveFollower(RemoveFollowerRequest) returns (CommandResponse);

message RemoveFollowerRequest {
  string actor_id    = 1;  // the followee — must be the authenticated caller
  string follower_id = 2;
}
```

Semantics: drop `follower_id → actor_id`. Leave the reverse edge alone. Do not
notify. Do not prevent re-following (that is what Block is for). Idempotent.

### Client status

`ProfileRelationshipsProviding.supportsFollowerRemoval` is a **deployment
capability**, injected at the composition root — not a feature flag or a user
preference. The mock implements removal, so the flow is verifiable in the
simulator today; against the fleet the row simply does not offer the action,
because a button that cannot work is worse than no button. Landing the RPC and
flipping the capability lights it up with no UI change.

---

## 3. Edges are id-only, and there is no batch profile read

### The cost

```proto
message EdgeSummary {
  string profile_id                        = 1;
  google.protobuf.Timestamp followed_at    = 2;
}
```

A row needs a display name, a handle, an avatar and a verification flag — none
of which are here — and `profile.v1` exposes only singular `GetProfileById`. So
**one screenful of 24 rows costs 25 requests**: the edge page, plus a
concurrent fan-out of 24 profile reads. Every page of scrolling costs another
24.

A second fan-out of the same size is avoided only by a workaround: each row also
needs "does the viewer follow this person", which `GetRelationStatus` answers
one profile at a time. The client instead reads the viewer's own follow list
**once** (`ListFollowing(viewer)`, capped at 500) and intersects. That is
correct but bounded — past the cap, a row can render "Follow" for someone the
viewer already follows. It self-corrects on tap, but it is a wrong state on
screen.

`followed_at` is never populated (mock or fleet), so the lists also can't be
ordered by, or display, when the follow happened — which is the natural sort
for a followers list.

### Proposal (preferred): embed the summary

```proto
message EdgeSummary {
  string profile_id                     = 1;
  google.protobuf.Timestamp followed_at = 2;  // and please populate it
  ProfileSummary profile                = 3;  // handle, display_name, avatar_url, verified
  ViewerContext viewer_context          = 4;  // see BACKEND_OPTIMIZATION_FOLLOW_STATE.md
}
```

This collapses 25 requests to 1 and removes the follow-set workaround entirely.
`ViewerContext` is the same block already proposed for timeline/search/profile
payloads in `BACKEND_OPTIMIZATION_FOLLOW_STATE.md` — the relationship lists are
a fourth caller for it, and the strongest one, because here the client needs it
per *row* rather than per screen.

### Fallback: batch profile reads

```proto
// profile.v1
rpc BatchGetProfiles(BatchGetProfilesRequest) returns (BatchGetProfilesResponse);
message BatchGetProfilesRequest  { repeated string profile_ids = 1; }
message BatchGetProfilesResponse { repeated ProfileView profiles = 1; }
```

Worth doing regardless of the above: the inbox's suggestions, the compose
picker, and the profile share sheet all run the same per-id fan-out today, for
the same reason.

---

## Summary of asks, in priority order

| # | Ask | Why |
|---|-----|-----|
| 1 | `ListAccess` on both list responses **+ server-side enforcement** | Privacy is currently client-inferred and unenforced |
| 2 | `follower_list_visibility` / `following_list_visibility` on `ProfileView` | Per-surface privacy cannot be expressed at all |
| 3 | `account.v1.Get/UpdatePrivacySettings` | No settings surface exists for a user to set the above |
| 4 | `social_graph.v1.RemoveFollower` | Users cannot remove their own followers |
| 5 | `ProfileSummary` + `ViewerContext` on `EdgeSummary` (or `BatchGetProfiles`) | 25 requests per screenful; bounded-sample follow state |
| 6 | Populate `EdgeSummary.followed_at` | Lists cannot be sorted or dated |
