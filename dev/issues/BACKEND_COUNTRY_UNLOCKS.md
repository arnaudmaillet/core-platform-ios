# Backend: country unlocks — which countries an account sees on the map, bought with gems

**Services:** `geo_discovery.v1` (filtering, standings), a wallet / economy
service (gems) · **Status:** proposal. The client is built and runs in mock
mode only.
**Client:** iOS Explore (map) tab, the country unlock sheet, the Countries
shop (map globe button, wallet sheet)
**Related:** `dev/BACKEND_GAPS.md` §24, §18 (semantic geo clusters),
`dev/economy/ECONOMY_CHARTER_V5.3.en.md` (gems)

## Summary

The map now draws every country's border (Natural Earth 1:50m, bundled in
the app). It shows posts **only in the countries the account has unlocked**.
Every other country is shaded and carries a badge at its centre with its
**rank** and its **likes**. Tapping it offers the country for **gems**.

- The unlocks belong to the **account**, not the profile: every profile of one
  account sees the same map.
- The account's **home country** is always unlocked, for free.
- The price comes from the country's activity rank:

  | rank | price |
  |---|---|
  | 1–10 | 50 gems |
  | 11–30 | 30 gems |
  | 31+ | 15 gems |
  | home country | 0 |

- **Only gems buy a country.** Points (the claimable currency spent on
  stakes) never do.

Today all of this is client-side:

- the unlocks are in `UserDefaults`, keyed by account id (`CountryUnlockStore`);
- the gems are the device wallet's ledger (`WalletStore.spendGems`);
- the standings are made up from the mock corpus over a population baseline
  (`CountryAccessService.standings`).

Against the fleet, the client passes no `CountryAccess`, so every country is
open and nothing is sold. **The client never filters the fleet's map on the
device's word.**

## Why this needs the backend

1. **An unlock is a purchase.** It spends a server-side balance and grants a
   durable entitlement. A device-local unlock is lost on reinstall, differs
   across devices, and anyone can forge it.
2. **The filter is an access rule.** "Posts in locked countries are not on
   your map" must hold on the server. Otherwise any client that skips the
   filter sees everything: the `QueryTile` response is the leak.
3. **The standings are global.** A country's rank and like count are
   aggregates over every post published there. Only the server has them.

## Ask

### 1. Entitlements: `country_access` (new, or on the economy service)

```proto
service CountryAccessService {
  // The account's unlocked countries (ISO 3166-1 alpha-2), home included.
  rpc GetCountryAccess(GetCountryAccessRequest) returns (GetCountryAccessResponse);
  // Spends gems and grants the country, atomically. Idempotent on request_id.
  rpc UnlockCountry(UnlockCountryRequest) returns (UnlockCountryResponse);
}

message GetCountryAccessResponse {
  string home_country = 1;               // "FR"; set at signup, from the account
  repeated string unlocked_countries = 2; // home included
  int64 gems_balance = 3;                 // so the sheet's balance line is one read
}

message UnlockCountryRequest {
  string country_code = 1;
  int64 expected_price = 2;  // the price the client showed; mismatch → FAILED_PRECONDITION
  string request_id = 3;     // idempotency: a retried tap must not charge twice
}

message UnlockCountryResponse {
  repeated string unlocked_countries = 1;
  int64 gems_balance = 2;
}
```

Error contract the client already handles:

| outcome | status | client |
|---|---|---|
| not enough gems | `FAILED_PRECONDITION` + detail `insufficient_gems { needed, have }` | button disabled, "You need N more gems" |
| already unlocked | `OK`, balance unchanged | sheet closes, country stays lifted |
| unknown code | `INVALID_ARGUMENT` | sheet closes |
| price changed since shown | `FAILED_PRECONDITION` + detail `price_changed { price }` | sheet re-reads the price (to build) |

`expected_price` matters because ranks move. A country can go from 30 to 50
gems between the badge being drawn and the tap. The charge must be the price
the user agreed to, or a visible refusal.

### 2. Standings: `GetCountryStandings` (geo_discovery)

```proto
rpc GetCountryStandings(GetCountryStandingsRequest) returns (GetCountryStandingsResponse);

message CountryStanding {
  string country_code = 1;
  int32 rank = 2;       // 1 = most active
  int64 likes = 3;      // likes on posts published there (window below)
  int64 posts = 4;
  int64 price_gems = 5; // for THIS account: 0 for home, the tier otherwise
}

message GetCountryStandingsResponse {
  repeated CountryStanding standings = 1; // every country, busiest first
  google.protobuf.Timestamp computed_at = 2;
}
```

- **Rank by likes** over a rolling window. We suggest 30 days, so a rank
  describes the country now, not all time. Ties are broken by country code,
  for a stable ladder.
- Returned **whole** (≈240 rows, ≈10 KB). The shop lists every country and
  the map badges them all, so paging buys nothing. The table is cacheable
  per account for minutes.
- `price_gems` comes from the server, so the tiers can change without an app
  release. The client's `CountryStanding.price(forRank:)` is only the mock's.

### 3. Filtering: `QueryTile` honours the entitlement

`QueryTileResponse.pins` (and clusters, and `GetGeoTimeline`) should contain
only posts whose country the caller has unlocked. Either:

- **(a)** filter server-side by the caller's entitlements (preferred: nothing
  locked ever reaches the device); or
- **(b)** add `string country_code = 7` to `RadarPin` and let the client
  filter. Cheaper to ship, but it is display, not access control.

Either way, **each post needs a stored country code**, resolved once at
publish time from its coordinates (reverse geocode, or a point-in-polygon on
the same Natural Earth admin-0 set the client bundles). Today the client
resolves it per pin with `CountryAtlas.country(containing:)`. That works, but
it is ~52k points of polygon tests the server could do once.

A post at sea, or outside every polygon, has an empty code and is always
shown. The client does the same.

### 4. Gems must be server-side first

The unlock spends gems. Gems are still a device ledger
(`WalletStore`: earned by settled stakes + granted − spent). The economy
service owning the gems balance is a precondition for (1). The mock seeds
100 gems per account (`WalletStore.Policy.seededGems`), enough for a few
countries. That grant is a mock convenience, not a product rule.

## Client seams, for whoever wires this

| client | today (mock) | against the fleet |
|---|---|---|
| `Maps.CountryAccess` protocol | `App/CountryAccessService` | an implementation over (1) + (2) |
| `isUnlocked(_:)` / `homeCountry` | `CountryUnlockStore` + `"FR"` | `GetCountryAccess` |
| `standings()` / `standing(of:)` | population baseline + mock likes | `GetCountryStandings` |
| `unlock(_:)` → `CountryUnlockOutcome` | `WalletStore.spendGems` then store | `UnlockCountry` |
| pin filter (`MapsViewController.isInUnlockedCountry`) | atlas lookup per pin | drop it for (3a), read `country_code` for (3b) |
| `.countryAccessDidChange` | wallet + store notifications | post after `UnlockCountry` / a refreshed `GetCountryAccess` |
