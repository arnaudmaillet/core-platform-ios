# Wallet: likes, gems, the hourly claim and stakes (`wallet.v1`)

> The app's currency A is **likes** (#1397). The wire keeps its field names (`points`, `points_cap`, `points_per_shot`, `points_earned`/`_spent`): they are the backend's contract, renamed only by a backend change.

**Status (2026-10-13):** the backend wallet exists. It is `wallet.v1` on the client edge (backend #665 and the follow-ups below), published on `buf.build/core-platform/contracts`. This document used to be the iOS team's *request* for that service. It now records **what the app binds to**, and what the client still keeps locally.

**Related:**
- `dev/economy/ECONOMY_CHARTER_V5.3.*.md`: the economy's design.
- Issues #676 (a like stakes the currency), #1098 (the server wallet), #1008 (welcome gift), #901 (likes cap), #903 (stakes list), #841 (this alignment).

---

## 1. The model

- **One wallet per account**, not per profile, with two currencies:
  - **likes** (currency A): what a like stakes;
  - **gems** (currency B): earned by stakes, spent in the shop.
- Every request carries `account_id`. The edge binds it to the token's subject; another account's id is `PERMISSION_DENIED`.
- **Every wallet RPC is authenticated.** A guest token is refused on all of them, so a guest never calls one. A guest's likes are the **welcome gift**, a locked pile shown on the device (`WelcomeGift`) until they sign up.
- A wallet opens on first use with **100 starter gems and 0 likes**.
- **Nothing is sold for real money.** There is no StoreKit and no restore. Gems are earned.
- Gems may not be spent under 18, or when the age is unknown: `Wallet.gem_spending_restricted`, `WAL-3001`. The app then hides the stake pack and the country unlocks.

## 2. Reading the wallet: `GetWallet`

`wallet.v1.WalletService/GetWallet(account_id)` returns `Wallet`:

| Fields | Meaning |
|---|---|
| `points`, `gems`, `points_earned` / `_spent`, `gems_earned` / `_spent` | balances and lifetime counters |
| `claim_available`, `next_claim_at`, `claim_amount` | the hourly claim (§3) |
| `claimed_today`, `daily_claim_cap`, `streak_days`, `last_claim_at` | the day's claims and the streak |
| `points_cap` | the balance a claim never takes past (§3) |
| `stake_shots`, `stake_pack_price`, `stake_pack_shots`, `points_per_shot` | the ×100 pack (§5) |
| `gem_spending_restricted` | see §1 |
| `conviction_probabilities` | the C1–C4 levels (§4, #1007) |

**The server is the clock.** The app draws the countdown from `next_claim_at` but never decides on the device that a claim is open. When `next_claim_at` passes, it reads the wallet again.

**App binding (#1098).**
- `WalletStore.server` is a `ServerWallet` (Feed) over this RPC.
- `WalletServerSync` (App) reads the wallet:
  - at launch;
  - on every viewer change, and again 3 s later, for the welcome gift (§6);
  - back in the foreground;
  - when the network returns;
  - just after `next_claim_at`.
- `WalletStore.apply` takes the answer as the truth. The balance shown is the server's likes minus the likes the outbox has not sent yet, which the device already deducted (§4).

## 3. The hourly claim: `ClaimReward`

`ClaimReward(account_id, idempotency_key)` returns `{ outcome, awarded, wallet }`.

- **The key** is 8–64 characters of `[A-Za-z0-9_-]` (otherwise `WAL-9002`). The app mints it **once per tap** and sends the same one with every retry of that tap. The server credits a key at most once and answers a replay with its first answer.
- **The outcomes are in-band**, each with the full `Wallet`, so there is no follow-up `GetWallet`:
  - `CLAIMED`: `awarded` likes credited;
  - `TOO_EARLY`: `wallet.next_claim_at` says when;
  - `DAILY_CAP_REACHED`: the next claim is at 00:00 UTC;
  - `BALANCE_FULL` (#901): the balance is at `points_cap`. `claim_available` is false **with no `next_claim_at`**: no wait opens it, only spending likes does.
- **Policy** (server config; the mock mirrors it):
  - 25 likes × the streak multiplier, which grows by 0.1 per consecutive UTC day and stops at ×2;
  - once an hour, at most 200 likes per UTC day;
  - `points_cap` 2,000. A claim that would pass it is clamped to what fits (`CLAIMED`).
- `ClaimReward` is also limited to about 30 calls an hour per account at the edge (`RESOURCE_EXHAUSTED`). A normal app never gets close.

## 4. Likes: `Stake`

A like is one unit of currency A **staked** on a post or a comment (#676). There is no reaction kind and no unlike. Like counts are read from `engagement.v1` (`BatchGetLikes`, and `ListLikesByProfile` for a profile's Liked tab). There is no `trending.v1`.

`Stake(account_id, profile_id, post_id | comment_id, points | use_stake_shot, idempotency_key, first_tap_at, conviction)` returns `{ outcome, spent, my_total, wallet }`.

- **Batched taps (the deferred commit).** The app records taps locally (`LikeOutbox`) and commits one batch per target with its own key:
  - 10 s after the last tap;
  - when the viewer moves on from the post;
  - when the app goes to the background.

  Until then a tap can be undone; after the commit it is final. There is no `UndoBoost` and no refund path.
- **`first_tap_at`**: a batch more than 24 h old is `EXPIRED`.
- **Outcomes, in the server's order:**
  - `EXPIRED`;
  - `OWN_CONTENT`: staking on one's own content is refused;
  - for a shot, room for a whole 100 (`SHOT_DOES_NOT_FIT`);
  - then the target's room, 250 likes per account ever (`TARGET_CAP_REACHED`);
  - the balance (`INSUFFICIENT_BALANCE`);
  - the hour's room, 1,000 likes (`RATE_LIMITED`).

  A plain batch is **clamped** to what fits, and `spent` says what was debited. The app gives the rest back (`settleCommittedStake`).
- **Conviction (#1007, backend #888).** `conviction` (C1–C4) is recorded and frozen with each batch, and has no effect yet. A quick tap sends `UNSPECIFIED`.

## 5. The ×100 stake pack

A pack of `stake_pack_shots` shots, each staking `points_per_shot` of the viewer's **own** likes in one tap. It costs `stake_pack_price` gems, read from the `Wallet`, never hard-coded. Gems buy the convenience, never likes.
- A shot is never clamped: room for less than a whole shot answers `SHOT_DOES_NOT_FIT`.
- A refusal keeps the shot.
- `BuyStakePack` is in the contract. The app still sells the pack from the local mock (§7).

## 6. The welcome gift

A guest's likes are a locked pile that grows with each day the app has been open: 50 + 25 × min(full days since first launch, 3). The server credits it **once per device**, when a sign-up or sign-in carrying the guest's refresh token ends the guest session (`guest_upgraded`, backend #934). It appears as `TRANSACTION_KIND_WELCOME_GIFT`.
- With a server wallet, the app does **not** credit it locally (`WelcomeGift.settle` only marks it settled, #1008). It reads the wallet again after the sign-in.
- The guest's refresh token always goes with `Login` and `SignUp`.

## 7. What is still local, and why

| Local | Until |
|---|---|
| Gems, stake shots, buying the pack, country unlocks | the gem catalogue and minting (backend #890, #892) |
| The stakes list on the claim sheet (`WalletStore.stakes()`, demo stakes) | #903: `ListMyStakes`, active / settled, outcome only while settlement is in shadow mode |
| Settlement and its gem rewards (`Policy.mockOutcome`, 6 h) | backend settlement: **24 h** after a position's first stake, and **shadow mode** (no gems minted) until backend #890 |

The mock (`MockWalletService`) mirrors §3 and §4 with one wallet per account, kept across launches. The app's mock wallet opens at 250 likes; package tests open one with a generous balance. It also credits the welcome gift (§6) when a guest becomes a member.
