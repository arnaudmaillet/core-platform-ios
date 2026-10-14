# Brand palette

The app's colours come from its icon (#1120): **tangerine** is primary and **violet** is secondary. Code reads **roles**, never hex values or system hues picked on the spot. The tokens live in `Packages/Core/DesignSystem/Sources/DesignSystem/Tokens/Palette.swift`. Decisions are recorded on #1124 (owner, 2026-10-13/14).

## Rules
- **Neutrals stay the system's.** Labels, backgrounds, fills, separators and `Surface` already adapt to dark mode, Increased Contrast and glass. `Palette` holds only the hues.
- **Tangerine marks what is interactive or selected.** It is the app's tint: `AccentColor` and the main window's `tintColor`. Every system control and every `.tintColor` read follows it.
- **A filled button wears a dark ink** (`onPrimary`). White on the vivid fill is 2.31:1 and fails.
- **Violet is secondary**: gems and secondary emphasis.
- **The brand gradient is for brand moments only**: splash, onboarding, empty-state art, the Shop's hero art. It is never used on recurring chrome (rings, like buttons, tab items).
- **A warning is a yellow glyph with neutral words** (`Warning`). Orange is the tint, and yellow text is about 1.5:1 on white.
- **Dark mode is not an inversion**: the dark tint is brighter. Roles near the contrast line have Increased Contrast values.

## Roles

| Role | Used for | Light | Dark | IC light / dark |
|---|---|---|---|---|
| `tint` | interactive glyphs, text buttons, switches, selection | `#C76300` | `#FFAD66` | `#8B4600` / `#FFD0AA` |
| `brandText` | links, @mentions, #hashtags in body text | `#B75F00` | `#FFAD66` | `#8B4600` / `#FFD0AA` |
| `primaryFill` / `onPrimary` | prominent filled button and its label | `#FF8D28` / `#2B1607` | `#FFAD66` / `#2B1607` | — |
| `prominentGlassTint` | a prominent glass button (Claim, Unlock): the glass draws its label white in either appearance | `#C76300` | `#C76300` | — |
| `primaryFillPressed` | pressed fill | `#F1800E` | `#F09F58` | — |
| `primaryContainer` / `onPrimaryContainer` | soft selected grounds, banners | `#FFECE0` / `#9F5100` | `#331B08` / `#FFA664` | — |
| `secondary` | gems, secondary emphasis | `#6852C6` | `#A78BFA` | `#5C44B7` / `#B59EFF` |
| `secondaryContainer` / `onSecondaryContainer` | gem grounds and badges | `#EFEEFF` / `#6852C6` | `#211944` / `#A78BFA` | — |
| `saveGold` | the saved star (#1128) | `#A07800` | `#FFC53D` (also over media) | — |
| `pointsGradient` | the Points heart (#1128) | `#C76300` → orange → pink | yellow → orange → pink | — |
| `brandGradient` | brand moments | `#B959DD` → `#FF8D28` | same | — |

Status colours stay the system's:
- success: `systemGreen`;
- error and destructive: `systemRed`;
- warning: `systemYellow`, as a glyph only.

## Contrast
`PaletteTests` checks every role where it is used, in both appearances (WCAG 2.x):
- glyph roles: 3:1 on `systemBackground` and `secondarySystemBackground`;
- text roles: 4.5:1 on `systemBackground` and the card;
- labels on brand grounds: 4.5:1.

## Out of the palette, on purpose
- User content inks (`MediaTextPalette`, the text style bar).
- Flag colours (`FlagPalette`).
- Measured inks over pictures (`HeroInk`).
- Surfaces pinned dark or light (editor, capture, QR card).
- Debug art.
- Verified seals, which stay blue (the convention).
- White-labelled swipe actions and the prominent-glass unlock button, which keep blue because the dark tangerine would fail their label.

## Guard
`RawHueGuardTests` (DesignSystem) scans `App/` and `Packages/` for raw colours (`UIColor(red:`, `UIColor(hue:`) and for the system hues the palette replaces. A file may keep one only with a reason on its list. CI only runs it in DesignSystem's lane, so when touching colours anywhere, run DesignSystem's tests too.
