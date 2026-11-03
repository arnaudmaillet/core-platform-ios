# Economy

The app's two-currency economy, as specified by the charter:

- [`ECONOMY_CHARTER_V5.3.fr.md`](ECONOMY_CHARTER_V5.3.fr.md) — the original (authoritative).
- [`ECONOMY_CHARTER_V5.3.en.md`](ECONOMY_CHARTER_V5.3.en.md) — English translation.

> **Shown as "Crowns" since #2072.** The currency the code and the contracts call **gems** (`Currency.gems`, `wallet.gemsGranted`, `GemSymbol`) is shown to the user as **Crowns**, with the owner's crown as its glyph (#2071). The name lives in `GemSymbol.name`, and its counted forms in `GemSymbol.amount(_:)` and `GemSymbol.more(_:)`.

## How the charter maps onto the app (25 September 2026)

| Charter | In the app | Glyph |
|---|---|---|
| **A** — curation capacity, spent when staking | **Likes** (the currency a like stakes; "points" until #1397) | `LikesSymbol` — a heart, red; the coin is a white heart on a red disc |
| **B** — earned-only reward, settled later | **Crowns** (#2072; **gems** in the code and on the wire) | `GemSymbol` — the owner's crown (#2071), deep gold on light grounds, yellow on dark |
| *Mise / miser* | **Stake / to stake** ("Active stakes", "Settled") | — |

Nothing on the wire carries stakes, settlements or B yet: the wallet surfaces
that show them run on mock data until the backend does.
