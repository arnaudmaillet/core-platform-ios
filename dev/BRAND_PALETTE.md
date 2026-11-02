# Brand palette

The app's colours are one **theme**: **raspberry**, used almost everywhere, with a violet for the gems and a raspberry → violet → mint signature gradient (#2062, the owner, 2026-11-02). Code reads **roles** (`Palette`), never hex values or system hues picked on the spot.

- The raw colours live in **one file**: `Packages/Core/DesignSystem/Sources/DesignSystem/Tokens/BrandTheme.swift`.
- The roles live in `Palette.swift` beside it, and every role derives from `BrandTheme.current`.
- The decisions are recorded on #1124, #1169, #1178, #1190 and #2062. The pink and violet palette that came before (#1169–#1190: `F37AB4`, the violet `7C5CF0` / `6852C6` / `A78BFA`) is history.

## Rules
- **Neutrals stay the system's.** Labels, backgrounds, fills, separators and `Surface` already adapt to dark mode, Increased Contrast and glass. `Palette` holds only the hues.
- **The UI is neutral** (#1169). The selected tab, secondary buttons, chips, the segmented selection and in-text mentions stay neutral.
- **The primary marks what matters**:
  - a screen's one primary action;
  - the system controls, through the app's tint (`AccentColor` and the main window's `tintColor`);
  - the unseen-story ring, the hearts, and every unread mark.
- **Every pill and badge is the solid primary** (`counter`), never a gradient, under a white count: the tab bar's badges, the bell's dot, the Messages selector's badges, the inbox's unread pills, the profile switcher's counts.
- **There is no secondary colour.** The violet is the gems' alone, and otherwise appears only inside the signature gradient, as the mint does.
- **Links, `@mentions` and `#hashtags` are a neutral grey** (`entityInk`), set apart by the semibold.
- **A filled button wears white** (`onPrimary`) in both appearances.
- **The signature gradient** (`brandGradient`) is for the launch logo and the unseen-story ring. **White text never sits over its mint half** (1.5:1), so no button wears it.
- **The system red is for errors and destruction only.**
- **A warning is a yellow glyph with neutral words** (`Warning`).
- **Dark mode is not an inversion.** Roles near the contrast line have Increased Contrast values.
- **One theme only** (the owner, 2026-11-02). The Shop's paid accent themes (#1379) are retired.
- **The yellow `FFE600` is recorded, not drawn** (`BrandTheme.crownYellow`): the crowns' colour, when crowns replace the gems.

## Roles

| Role (`BrandTheme`) | Used for | Light | Dark | IC light / dark |
|---|---|---|---|---|
| `primary` → `tint`, `brandText` | interactive glyphs, text buttons, switches, selection | `EC1C75` | `EC1C75` | `C2105F` / `F25C9A` |
| `primaryFill` | a filled button's ground | `EC1C75` | `EC1C75` | `C2105F` / `C2105F` |
| `primarySolid` → `prominentFill`, `prominentGlassTint` | the prominent fill and the prominent glass's tint | `EC1C75` | `EC1C75` | — |
| `onPrimary` | the label on the fill | `FFFFFF` | `FFFFFF` | — |
| `primaryPressed` | the pressed fill | `D41868` | `D41868` | `A80D52` / `D41868` |
| `primaryContainer` / `onPrimaryContainer` | soft selected grounds, the streak chip | `FDE3EE` / `B00E57` | `3D0A20` / `F57BAE` | — |
| `counter` | every unread mark, pill and badge | `EC1C75` | `EC1C75` | `C2105F` / `C2105F` |
| `entityInk` | `@mentions`, `#hashtags`, links | `5E5E66` | `AEAEB4` | `48484F` / `C8C8CD` |
| `likes` | the likes' heart, glyph and coin | `EC1C75` | `EC1C75` | `C2105F` / `F25C9A` |
| `gem` → `gemViolet`, `GemSymbol.tint` | the gems' glyph | `9B5CFF` | `9B5CFF` | `7A3FE0` / `B48AFF` |
| `gemText` → `GemSymbol.textColor` | a gem amount or price as text | `7A3FE0` | `A97AFF` | `6E33D6` / `B48AFF` |
| `saveGold` | the saved star | `FFC53D` | `FFC53D` | — |
| `signatureGradient` → `brandGradient` | the launch logo, the story ring | `EC1C75` 0 · `9B5CFF` 0.5 · `2EF0A8` 1 | same | — |
| `loaderTones` | the branded loader's pills | `EC1C75`, `9B5CFF`, `2EF0A8` | same | — |

### Measured contrast (WCAG 2.x)
| Pair | Light | Dark | IC light | IC dark |
|---|---|---|---|---|
| `tint` on the page (white / black) | 4.21 | 4.99 | 5.94 | 6.77 |
| `tint` on the raised ground (`F2F2F7` / `1C1C1E`) | 3.77 | 4.04 | 5.33 | 5.49 |
| white on `primaryFill` | 4.21 | 4.21 | 5.94 | 5.94 |
| white on `counter` | 4.21 | 4.21 | 5.94 | 5.94 |
| `onPrimaryContainer` on `primaryContainer` | 5.71 | 6.59 | — | — |
| `entityInk` on the page | 6.42 | 9.51 | 9.07 | 12.60 |
| `gemViolet` (glyph) on the page | 3.91 | 5.37 | 5.81 | 8.02 |
| `gemText` on the page / the card | 5.81 / 5.81 | 6.91 / 5.60 | 6.76 | 8.02 / 6.50 |

The raspberry is 4.21:1 as text on white: the owner's base 500. Text in the accent reaches 4.5:1 under Increased Contrast.

Status colours stay the system's:
- success: `systemGreen`;
- error and destructive: `systemRed`;
- warning: `systemYellow`, as a glyph only.

### Not the theme
These sit in `BrandTheme.swift` only because they are hex. A theme change leaves them alone:
- `BrandNeutrals`: the grouped page's light grey, which the loader mixes toward;
- `BrandCosmetics`: the avatar frames' sweeps (gold, neon, aurora). A frame is a cosmetic item, the same object for everyone.

## The assets
Three assets hold the brand outside the code. `BrandAssetsGuardTests` (DesignSystem) reads each one and checks it against `BrandTheme.current`:

| Asset | Holds | `BrandTheme` field |
|---|---|---|
| `App/Resources/Assets.xcassets/AccentColor.colorset` | the app's tint: light, dark and the Increased Contrast pair | `primary` |
| `App/Resources/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.svg` | the launch logo's pale gradient | `launchLogoStops` |
| `App/Resources/AppIcon.icon/icon.json` | the icon's blob fill, as Icon Composer writes it | `iconGradient` |

## Changing the theme
1. **Write the new values** in `BrandTheme.swift`: a new `BrandTheme` value, then point `current` at it. Call sites do not change, because they read `Palette`'s roles.
2. **Update the assets** until `BrandAssetsGuardTests` passes:
   - `AccentColor`'s four values;
   - the launch logo's stops;
   - the icon, redone in Icon Composer. Copy its `.icon` byte for byte, then copy its fill strings into `iconGradient`.
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
