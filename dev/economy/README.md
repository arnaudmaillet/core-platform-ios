# Economy

The app's two-currency economy, as specified by the charter:

- [`ECONOMY_CHARTER_V5.3.fr.md`](ECONOMY_CHARTER_V5.3.fr.md) — the original (authoritative).
- [`ECONOMY_CHARTER_V5.3.en.md`](ECONOMY_CHARTER_V5.3.en.md) — English translation.

## How the charter maps onto the app (25 September 2026)

| Charter | In the app | Glyph |
|---|---|---|
| **A** — curation capacity, spent when staking | **Points** (today's likes / boosts) | `PointsSymbol` — a heart, red; the coin is a white heart on a red disc |
| **B** — earned-only reward, settled later | **Gems** | a diamond (`diamond.fill`) |
| *Mise / miser* | **Stake / to stake** ("Active stakes", "Settled") | — |

Nothing on the wire carries stakes, settlements or B yet: the wallet surfaces
that show them run on mock data until the backend does.
