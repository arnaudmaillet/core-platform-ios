# Backend: virtual currency wallet, reward claims, and trending boosts

**Requested by:** iOS client team
**Area:** `wallet.v1` (new service), `trending.v1` (new service or extension of the
ranking pipeline), touches `counter.v1` (score projections)
**Type:** new capability — no wallet, points, or boost concept exists anywhere in
the current contracts
**Related:** `dev/BACKEND_GAPS.md` (general gap register); the iOS client ships a
fully client-side mock (`WalletStore`) in the meantime, described in §6

The iOS client is shipping a **virtual currency & trending boost** surface:
a coin balance in the map screen's toolbar, periodic point claims with a daily
cap and streak, and a **Boost** button on posts and comments that spends points
to raise their trending rank. All of it currently runs against a local mock
store. This document specifies the backend contract the client wants to bind
to, so the mock can be deleted rather than reverse-engineered later.

Endpoint names below are given in both shapes: the REST-ish path (as the
product spec phrases it) and the Connect RPC the BFF edge would actually
expose. The client speaks Connect; the REST paths are aliases.

---

## 1. `GET /user/wallet` — read the wallet

**RPC:** `wallet.v1.WalletService/GetWallet` (idempotent, safe for Connect GET)

Returns the caller's wallet. There is no "create wallet" call — the wallet is
provisioned lazily on first read, with `balance = 0` and the claim immediately
available.

```proto
// wallet.v1
message GetWalletRequest {}  // caller identity comes from auth, never from the request

message Wallet {
  string profile_id                        = 1;
  int64  balance                           = 2;  // spendable points, never negative
  int64  lifetime_earned                   = 3;
  int64  lifetime_spent                    = 4;

  // Claim state — everything the client needs to render the claim surface
  // without doing its own timer math against a possibly-skewed local clock.
  bool   claim_available                   = 5;
  google.protobuf.Timestamp next_claim_at  = 6;  // meaningful when claim_available == false
  int32  claim_amount                      = 7;  // what the NEXT claim will pay (after streak multiplier)
  int32  claimed_today                     = 8;  // points earned via claims in the current UTC day
  int32  daily_claim_cap                   = 9;  // server policy, returned so the client never hardcodes it
  int32  streak_days                       = 10; // consecutive UTC days with >= 1 claim
  google.protobuf.Timestamp last_claim_at  = 11;
}

message GetWalletResponse {
  Wallet wallet = 1;
}
```

Notes:

- **The server is the clock.** `claim_available` and `next_claim_at` are
  computed server-side. The client renders a countdown from `next_claim_at`
  but never decides eligibility locally (the mock currently does, and it is
  exactly the kind of logic that must not survive into production — a device
  clock rolled forward mints points).
- `daily_claim_cap` and `claim_amount` are echoed policy, not client config,
  so ops can tune reward economics without an app release.
- Suggested initial policy (client mock ships with these): claim every
  **1 hour**, base claim **25 points**, daily cap **200 points/day**, streak
  multiplier +10 %/consecutive day capped at 2× (see §4.4).

## 2. `POST /user/wallet/claim` — claim reward points

**RPC:** `wallet.v1.WalletService/ClaimReward` (mutating, idempotent per key)

```proto
message ClaimRewardRequest {
  // Client-generated UUID. Two requests with the same key MUST return the
  // same response and credit at most once (retries over flaky mobile links).
  string idempotency_key = 1;
}

message ClaimRewardResponse {
  ClaimOutcome outcome     = 1;
  int32        awarded     = 2;  // points credited by THIS call (0 unless CLAIMED)
  Wallet       wallet      = 3;  // full post-claim state, saves a follow-up GetWallet
}

enum ClaimOutcome {
  CLAIM_OUTCOME_UNSPECIFIED = 0;
  CLAIMED                   = 1;
  TOO_EARLY                 = 2;  // next_claim_at not reached; wallet carries the timestamp
  DAILY_CAP_REACHED         = 3;  // claimed_today >= daily_claim_cap
}
```

Notes:

- **In-band outcomes, not error codes.** `TOO_EARLY` and `DAILY_CAP_REACHED`
  are ordinary states the UI renders (disabled button + countdown), not
  failures. Reserve gRPC errors for actual faults (`UNAUTHENTICATED`,
  `RESOURCE_EXHAUSTED` for abuse, `INTERNAL`).
- The response embeds the full `Wallet` so a claim is one round trip:
  tap → new balance, new `next_claim_at`, new streak.
- Streak accounting: `streak_days` increments on the first successful claim
  of a UTC day if the previous UTC day had at least one claim; otherwise it
  resets to 1. Timezone-per-user is explicitly out of scope for v1 (see §7).

## 3. `POST /posts/{id}/boost` and `POST /comments/{id}/boost` — spend points on rank

**RPC:** `trending.v1.BoostService/Boost` — one RPC, typed target. Two path
aliases at the edge if REST ergonomics matter, but the client prefers a single
RPC because post- and comment-boosting share every rule below.

```proto
// trending.v1
message BoostTarget {
  oneof target {
    string post_id    = 1;
    string comment_id = 2;
  }
}

message BoostRequest {
  BoostTarget target     = 1;
  int32  amount          = 2;  // points to spend; server validates against allowed denominations
  string idempotency_key = 3;  // same contract as ClaimReward
}

message BoostResponse {
  BoostOutcome outcome    = 1;
  int64  new_balance      = 2;  // caller's wallet after the spend
  int64  target_boost_total = 3;  // total points ever boosted into this target, all users
  int32  my_boost_total     = 4;  // caller's cumulative spend on this target
}

enum BoostOutcome {
  BOOST_OUTCOME_UNSPECIFIED = 0;
  BOOSTED                   = 1;
  INSUFFICIENT_BALANCE      = 2;
  TARGET_NOT_BOOSTABLE      = 3;  // deleted/moderated target, or boosting disabled on it
  RATE_LIMITED              = 4;  // per-user or per-target velocity limit (§4.5)
  INVALID_AMOUNT            = 5;  // not one of the allowed denominations
  TARGET_CAP_REACHED        = 6;  // this viewer's per-target allowance (§4.5) is full
}
```

Notes:

- **Allowed denominations are server policy.** v1: `{100}` plus free-form
  amounts up to the per-target cap (the client's "Max" menu entry sends the
  computed remainder, so the server must accept arbitrary `amount ≤ cap
  remainder`, not just the listed denominations). A plain tap spends 10.
  Echo the policy in `GetWalletResponse` if it ever needs to vary.
- **Per-target cap, clamp semantics.** One viewer can put at most **250
  points** on one target, lifetime. A spend that would overshoot is CLAMPED
  to the remainder — `BoostResponse` then reports the actual debit (add
  `int32 spent = 5` to the response) — and a full target answers
  `TARGET_CAP_REACHED`. The client mirrors both behaviours exactly
  (`WalletStore.Policy.perTargetBoostCap`).
- **Boosting is irreversible.** No refund RPC. Moderated-away targets do not
  refund spenders (this kills a laundering vector: boost, report own post,
  collect refunds — any refund path needs its own abuse review first).
- **Self-boost is allowed in v1** (it is the primary use case — promoting
  your own post) but must be attributable in the ledger (§4.2) so policy can
  change without a schema change.
- `target_boost_total` lets the client animate the score increment from an
  authoritative number instead of guessing.

### 3.1 How boost affects trending rank

The client takes no position on ranking internals, but the contract needs one
decision made explicitly: **boost weight must decay.** A flat additive score
means week-old posts with deep-pocketed authors permanently occupy trending.
Suggested shape (matches the industry-standard half-life approach):

```
effective_boost(t) = Σ over boosts b of: b.amount * 0.5 ^ ((t - b.created_at) / HALF_LIFE)
HALF_LIFE = 24h initially, ops-tunable
```

`effective_boost` feeds the trending scorer as one weighted input next to
organic signals (reactions, comments, views from `counter.v1`). Boost must
never be able to outrank organic signal by more than a bounded factor —
suggest capping boost's contribution at some percentile of organic score so
the feed stays a feed and not an auction.

### 3.2 Session undo (a client behavior the contract should know about)

The client ships an UNDO on boosts, deliberately narrow: a boost can be taken
back only **while the boosted post is still the post on screen** — paging
away, or leaving the screen, finalizes it. In the mock this is a plain
compensating credit; against a real service it needs one of:

- **A. Deferred commit (preferred).** The client batches a post's boosts
  locally and issues ONE `Boost` when the viewer moves on. No new RPC, no
  refund path, and the rate limiter sees fewer, larger spends. Cost: a boost
  is invisible to other viewers for the seconds the post stays on screen —
  acceptable for a ranking signal.
- **B. `UndoBoost` with a server-enforced window.** Same idempotency contract
  as `Boost`; refuses (`WINDOW_EXPIRED`) beyond a short TTL (suggest 5 min)
  or from a different session. Strictly more moving parts than A, and the
  §3 "no refunds" stance stays true for everything outside the window.

Either way the general rule stands: **no open-ended refunds** (§5).

## 4. Data models

### 4.1 `wallets`

| column | type | notes |
|---|---|---|
| `profile_id` | PK | one wallet per profile |
| `balance` | int64, `CHECK >= 0` | authoritative spendable balance |
| `lifetime_earned` / `lifetime_spent` | int64 | monotonic counters |
| `last_claim_at` | timestamptz | |
| `claimed_today` | int32 | reset lazily on first read/claim of a new UTC day |
| `claimed_today_date` | date | the UTC day `claimed_today` refers to |
| `streak_days` | int32 | |
| `updated_at` | timestamptz | |

### 4.2 `point_transactions` — append-only ledger

Every balance mutation is a ledger row; `wallets.balance` is a materialized
view of the ledger and must be reconcilable against `SUM(delta)` at any time.

| column | type | notes |
|---|---|---|
| `id` | PK (ULID) | |
| `profile_id` | FK | indexed |
| `delta` | int64 | positive = credit, negative = debit |
| `kind` | enum | `CLAIM`, `BOOST_SPEND`, `ADMIN_ADJUST`, (future: `PURCHASE`, `REFUND`) |
| `ref_id` | string | boost id for `BOOST_SPEND`, null for `CLAIM` |
| `idempotency_key` | string | **unique per profile** — this constraint IS the idempotency mechanism |
| `created_at` | timestamptz | |

### 4.3 `boosts` / `boost_scores`

| column | type | notes |
|---|---|---|
| `id` | PK (ULID) | |
| `target_kind` | enum | `POST`, `COMMENT` |
| `target_id` | string | indexed with `target_kind` |
| `booster_profile_id` | FK | attribution (self-boost analytics, abuse tooling) |
| `amount` | int32 | |
| `created_at` | timestamptz | decay input (§3.1) |

Plus a rolled-up `boost_scores(target_kind, target_id, total_amount,
effective_boost, computed_at)` projection refreshed by the ranking job, so
read paths never scan the raw boost table.

### 4.4 Claim/streak policy (initial values)

| knob | v1 value |
|---|---|
| claim interval | 1 hour |
| base claim amount | 25 points |
| daily claim cap | 200 points / UTC day |
| streak multiplier | ×(1 + 0.1 × (streak_days − 1)), capped ×2.0 |
| streak reset | one full UTC day with zero claims |

### 4.5 Rate limiting & abuse rules

- **Idempotency:** unique `(profile_id, idempotency_key)` on the ledger;
  replays return the stored response. Applies to claim and boost identically.
- **Claim velocity:** the interval itself is the limiter, but additionally
  cap `ClaimReward` calls at ~30/hour/profile (`RESOURCE_EXHAUSTED`) so a
  hammering client can't turn the outcome check into load.
- **Boost velocity:** per-user ceiling (suggest 1 000 points/hour) returned
  as `RATE_LIMITED`; the per-target allowance is the LIFETIME cap of §3
  (250/viewer/target, `TARGET_CAP_REACHED`) — a velocity window on top is
  unnecessary once the lifetime cap exists.
- **Serialization:** balance check + debit + boost insert in one transaction
  with the wallet row locked (`SELECT … FOR UPDATE`). Two concurrent boosts
  must not double-spend; the `CHECK (balance >= 0)` is the backstop.
- **New-account gating:** consider withholding claims for accounts younger
  than 24 h — points farming via throwaway accounts is the obvious attack.

## 5. Out of scope for v1 (flagged so nobody designs the schema into a corner)

- Purchasing points with real money (App Store IAP has its own review and
  ledger `kind` reserved: `PURCHASE`).
- Transfers/gifting between users.
- Refunds of any kind (the session undo of §3.2 is a commit-window question,
  not a refund feature).
- Per-user timezone streak accounting (UTC day everywhere in v1).

## 6. What the client ships in the meantime

`WalletStore` (iOS, `Packages/Core/CoreStorage`): a local mock with the exact
`Wallet` shape above — UserDefaults persistence, server-policy constants from §4.4,
hourly claim timer, daily cap, streak, and optimistic boost spends. All
mutation goes through the same `ClaimOutcome`/`BoostOutcome` enums, so binding
to the real service is a transport swap, not a redesign. The mock's known
lies, accepted for now:

- device clock is trusted (the reason §1 insists the server owns the clock);
- boosts mutate a local score only — trending rank is unaffected;
- balances are per-device, not per-account.

## 7. Open questions for the backend team

1. Does boost feed the existing ranking pipeline as a `counter.v1` projection,
   or does `trending.v1` own its own read path? The client only needs
   `target_boost_total` on the boost response either way.
2. Should `GetWallet` piggyback on an existing bootstrap call (session
   hydration) instead of being its own round trip on app start?
3. Half-life and cap values in §3.1 — who owns tuning, and is there an
   experimentation surface for them?
4. §3.2: deferred commit vs. windowed `UndoBoost` — the client can bind to
   either, but the choice decides whether `Boost` stays the contract's only
   spend mutation.
