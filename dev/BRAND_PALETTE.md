# Brand palette

The app's colours are one **theme**: **coral** — the primary `FF1358`, used almost everywhere, a mint `16FFCB` as the brand's second colour, a gold crown for the gems (#2071) and a violet → mint signature gradient (#2282, the owner, 2026-11-11). Code reads **roles** (`Palette`), never hex values or system hues picked on the spot.

- The raw colours live in **one file**: `Packages/Core/DesignSystem/Sources/DesignSystem/Tokens/BrandTheme.swift`.
- The roles live in `Palette.swift` beside it, and every role derives from `BrandTheme.current`.
- The decisions are recorded on #1124, #1169, #1178, #1190, #2062 and #2282. What came before is history: the raspberry `EC1C75` and its raspberry → violet `9B5CFF` → mint `2EF0A8` signature (#2062), and before it the pink and violet palette (#1169–#1190: `F37AB4`, the violet `7C5CF0` / `6852C6` / `A78BFA`).

## Rules
- **Neutrals stay the system's.** Labels, backgrounds, fills, separators and `Surface` already adapt to dark mode, Increased Contrast and glass. `Palette` holds only the hues.
- **The post lists lie on the plain page** (#2243; the only style since #2290, Release included). The profile, the place page, For You's pages and the post sets lie on `Surface.plainPage` (white / black); their text posts are flat rows parted by `separator` hairlines. A tile of words and a shelf's media card wear `Surface.cardOnPlainPage` there. Every other screen keeps the grouped grey (`Surface.page`) and its cards (`Surface.card`): Settings, the grouped lists, the sheets.
- **The UI is neutral** (#1169). The selected tab, secondary buttons, chips, the segmented selection and in-text mentions stay neutral.
- **The primary marks what matters**:
  - a screen's one primary action;
  - the system controls, through the app's tint (`AccentColor` and the main window's `tintColor`);
  - the unseen-story ring, the hearts, and every unread mark.
- **Every pill and badge is the solid primary** (`counter`), never a gradient, under a white count: the tab bar's badges, the bell's dot, the Messages selector's badges, the inbox's unread pills, the profile switcher's counts.
- **The mint is the brand's second colour, not a UI colour** (#2282 § 3, the owner's pick). It is the icon's, the launch logo's and the signature's end. The theme holds it (`accent`, `accentText`, with a deep mint for light grounds, where the mint itself is 1.16:1 on the page), but no `Palette` role reads it. A place that wants the mint is a follow-up the owner names, with the deep mint on light grounds.
- **The violet appears only inside the signature gradient**, never as a UI colour on its own.
- **Links, `@mentions` and `#hashtags` are a neutral grey** (`entityInk`), set apart by the semibold.
- **A filled button wears white** (`onPrimary`) in both appearances.
- **The signature gradient** (`brandGradient`, #2282) runs violet `7235FF` → mint `16FFCB`, without the primary: a gradient from the primary to the mint goes grey in the middle (`8A8992`), where violet → mint stays coloured through a sky blue (`449AE5`). **The unseen-story ring** (`storyRingGradient`, #2089) and **the loader** (`loaderGradient`, #2147) wear it. Under Increased Contrast both wear `signatureContrastStops`: opaque, the mint end deepened to `009E7B` (3.05:1 on the light page). **White text never sits over its mint half** (1.30:1), so no button wears it; it holds on the violet end (5.72:1).
- **The system red is for errors and destruction only.**
- **A warning is a yellow glyph with neutral words** (`Warning`).
- **Dark mode is not an inversion.** Roles near the contrast line have Increased Contrast values.
- **One theme only** (the owner, 2026-11-02). The Shop's paid accent themes (#1379) are retired.
- **The gems wear the crown's yellow** (#2071): `FFE600` wherever it reads (dark grounds, the washes), a bright gold `F5C000` on light grounds (the owner's pick, 2026-11-03), where the yellow is 1.27:1. The bright gold is under a glyph's 3:1 there, so the crown always stands beside its amount; Increased Contrast takes it to `A87C00`. The violet now lives only in the signature gradient. The saved star keeps its own gold (`FFC53D`), apart from the crowns.

## Roles

| Role (`BrandTheme`) | Used for | Light | Dark | IC light / dark |
|---|---|---|---|---|
| `primary` → `tint` | interactive glyphs, switches, selection, the tint | `FF1358` | `FF1358` | `C6003A` / `FF5C8C` |
| `primaryText` → `brandText` | text in the primary: a "See all", a text button | `EB0045` | `FF1358` | `C6003A` / `FF5C8C` |
| `primaryFill` | a filled button's ground | `FF1358` | `FF1358` | `C6003A` / `C6003A` |
| `primarySolid` → `prominentFill`, `prominentGlassTint` | the prominent fill and the prominent glass's tint | `FF1358` | `FF1358` | — |
| `onPrimary` | the label on the fill | `FFFFFF` | `FFFFFF` | — |
| `primaryPressed` | the pressed fill | `DA0040` | `DA0040` | `AA0032` / `DA0040` |
| `primaryContainer` / `onPrimaryContainer` | soft selected grounds, the streak chip, tinted row actions | `FFE3EB` / `B20034` | `3D0515` / `FF7DA3` | — |
| `counter` | every unread mark, pill and badge | `FF1358` | `FF1358` | `C6003A` / `C6003A` |
| `accent` | the mint as a glyph — **no role reads it** (§ 3) | `009E7B` | `16FFCB` | `008567` / `16FFCB` |
| `accentText` | the mint as text — **no role reads it** | `008567` | `16FFCB` | `007157` / `16FFCB` |
| `entityInk` | `@mentions`, `#hashtags`, links | `5E5E66` | `AEAEB4` | `48484F` / `C8C8CD` |
| `likes` | the likes' heart, glyph and coin | `FF1358` | `FF1358` | `C6003A` / `FF5C8C` |
| `gem` → `Palette.gem`, `GemSymbol.tint` | the gems' glyph, the crown | `F5C000` | `FFE600` | `A87C00` / `FFE600` |
| `gemText` → `GemSymbol.textColor` | a gem amount or price as text | `8A6400` | `FFE600` | `7A5800` / `FFE600` |
| `gemGround` → `GemSymbol.ground` | the wash under a price or a claim, at the reader's alpha | `FFE600` | `FFE600` | — |
| `saveGold` | the saved star | `FFC53D` | `FFC53D` | — |
| `signatureGradient` → `brandGradient`, `storyRingGradient`, `loaderGradient` | the unseen-story ring (#2089), the loader (#2147); sRGB interpolation | `7235FF` 0 · `16FFCB` 1 | same | `signatureContrastStops`: `7235FF` · `009E7B`, opaque |
| `loaderOpacities` | each signature stop's opacity in the loader (its softness, the loader's own) | 0.75 · 0.55 | same | opaque |

### Measured contrast (WCAG 2.x)
The raised ground is `F2F2F7` in the light and `1C1C1E` in the dark in every column.

| Pair | Light | Dark | IC light | IC dark |
|---|---|---|---|---|
| `tint` on the page (white / black) | 3.83 | 5.49 | 6.07 | 7.16 |
| `tint` on the raised ground | 3.43 | 4.44 | 5.44 | 5.80 |
| `brandText` on the page (white / black) | 4.55 | 5.49 | 6.07 | 7.16 |
| `brandText` on the raised ground | 4.07 | 4.44 | 5.44 | 5.80 |
| white on `primaryFill` | 3.83 | 3.83 | 6.07 | 6.07 |
| white on `primaryPressed` | 5.18 | 5.18 | 7.62 | 5.18 |
| white on `counter` | 3.83 | 3.83 | 6.07 | 6.07 |
| `onPrimaryContainer` on `primaryContainer` | 5.93 | 7.08 | — | — |
| `accent` on the page / the raised ground | 3.40 / 3.05 | 16.20 / 13.13 | 4.61 / 4.14 | 16.20 / 13.13 |
| `accentText` on the page / the raised ground | 4.61 / 4.14 | 16.20 / 13.13 | 6.00 / 5.38 | 16.20 / 13.13 |
| the signature's violet `7235FF` on white (white text on it too) / the light page | 5.72 / 5.13 | 3.67 on black | — | — |
| the signature's mint end on the light page (`F2F2F7`) | 1.16 (`16FFCB`) | — | 3.05 (`009E7B`) | — |
| `entityInk` on the page | 6.42 | 9.51 | 9.07 | 12.60 |
| `gem` (glyph) on the page / the raised ground | 1.69 / 1.51 | 16.57 / 13.43 | 3.79 / 3.39 | 16.57 |
| `gemText` on the page / the raised ground | 5.38 / 4.82 | 16.57 / 13.43 | 6.51 / 5.84 | 16.57 |
| `gemText` on a price bubble (`gemGround` at 0.16 / 0.35, on white) | 5.13 / 4.86 | 8.82 (at 0.16, on the card) | — | — |

- **`FF1358` is 3.83:1 on white**: past the 3:1 a glyph, the tint, the hearts and the counters need everywhere. A filled button's white label is semibold at the button's size, so 3:1 holds for it, at 3.83.
- **Text in the primary wears `brandText`**: a deeper shade of the same hue in the light only (`EB0045`, 4.55:1 on white and on the card, which is white in the light). In the dark it is the primary itself, 5.49:1 on black and 4.44:1 on the dark card. Increased Contrast takes it to `C6003A` in the light (6.07:1, the white label on the IC fill too) and lifts it to `FF5C8C` in the dark (7.16:1 on black).
- **The mint is 1.30:1 on white and 1.16:1 on the light page**: invisible as a glyph or text there, so a light ground wears the deep mint (`009E7B` for a glyph, `008567` for text). Never white text on the mint (1.30:1); black on it is 16.2:1.

Status colours stay the system's:
- success: `systemGreen`;
- error and destructive: `systemRed`;
- warning: `systemYellow`, as a glyph only.

### Not the theme
These sit in `BrandTheme.swift` only because they are hex. A theme change leaves them alone:
- `BrandNeutrals`: the grouped page's light grey, which the loader mixes toward;
- `BrandCosmetics`: the avatar frames' sweeps (gold, neon, aurora). A frame is a cosmetic item, the same object for everyone.

## The assets
Three assets hold the brand outside the code. `BrandAssetsGuardTests` (DesignSystem) reads each one:

| Asset | Holds | Checked against |
|---|---|---|
| `App/Resources/Assets.xcassets/AccentColor.colorset` | the app's tint: light, dark and the Increased Contrast pair (Xcode's "accent" is the **tint**: it carries the primary, not the mint) | `BrandTheme.primary` |
| `App/Resources/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.svg` | the launch logo: the mark in the primary, its echo in the mint, at the icon's offset and scale. One SVG for both appearances: the echo sits on the primary mark, where the mint stands out (2.95:1 against `FF1358`) and the deep mint would not (1.13:1) | `BrandTheme.primary`, then `accent` (the mint, its dark value) |
| `App/Resources/AppIcon.icon/icon.json` | the icon's solid ground, and the fill of its mint glass layer (the mark's echo). Both layers draw the one mark, `Assets/mark.svg` | the ground: `primary`; the mint layer: `accent` (the mint), each within one unit per sRGB channel once converted from `srgb:` or `display-p3:` |

The icon's mint layer is written in display-p3 (`0.46658, 0.98557, 0.80754`), the mint `16FFCB` within 0.4 of a unit. Its strength (0.4 fill alpha, 0.6 opacity) is the owner's: over the white mark it renders a pale grey (#2282, problem 1).

## Changing the theme
1. **Write the new values** in `BrandTheme.swift`: a new `BrandTheme` value, then point `current` at it. Call sites do not change, because they read `Palette`'s roles.
2. **Update the assets** until `BrandAssetsGuardTests` passes:
   - `AccentColor`'s four values (the primary's);
   - the launch logo;
   - the icon, in Icon Composer: copy the `.icon` byte for byte, and render it with `ictool` (light, dark, tinted, clear).
3. **Check the contrast.** `PaletteTests` and `PaletteThemeTests` measure every role where it is used, and `PaletteTests.everyRoleIsTheThemes` checks each role against `BrandTheme.current`. Update the table above.
4. **Update this document's tables.**
5. **Run the full suite and a Release build.** `Palette` is read everywhere.

If paid themes come back one day, a theme is a second `BrandTheme` value plus a trait that picks one.

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
- White-labelled swipe actions, which keep their system grounds.

## Guards
- **`RawHueGuardTests`** (DesignSystem) has two scans over `App/` and `Packages/` (sources, not tests):
  - raw colours (`UIColor(red:`, `UIColor(hue:`) and the system hues the palette replaces. A file may keep one only with a reason on its list;
  - hex colour literals (`0xF37AB4`), which are allowed only in `BrandTheme.swift`.
- **`BrandAssetsGuardTests`** (DesignSystem) checks the three assets above.

CI only runs them in DesignSystem's lane, so when you touch colours anywhere, run DesignSystem's tests too.
