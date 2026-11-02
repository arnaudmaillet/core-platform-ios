# Brand palette

The app's colours are one **theme**: a pink primary and a violet secondary, from the icon (#1169, #1176, #1190). Code reads **roles** (`Palette`), never hex values or system hues picked on the spot.

- The raw colours live in **one file**: `Packages/Core/DesignSystem/Sources/DesignSystem/Tokens/BrandTheme.swift` (#2062).
- The roles live in `Palette.swift` beside it, and every role derives from `BrandTheme.current`.
- The decisions are recorded on #1124, #1169, #1178, #1190 and #2062.

## Rules
- **Neutrals stay the system's.** Labels, backgrounds, fills, separators and `Surface` already adapt to dark mode, Increased Contrast and glass. `Palette` holds only the hues.
- **The UI is neutral** (#1169). The selected tab, secondary buttons, chips, the segmented selection and in-text mentions stay neutral.
- **The primary marks what matters**:
  - a screen's one primary action;
  - the system controls, through the app's tint (`AccentColor` and the main window's `tintColor`);
  - the unseen-story ring and the hearts.
- **Unread counts and the bell's dot are the violet `counter`** (#1178). The system red is for errors and destruction only.
- **A filled button wears white** (`onPrimary`) in the light, and a dark ink on the dark-mode fill.
- **Violet is secondary**: gems, secondary emphasis, the gradients' far stop and, greyed, the ink of links and tokens (`entityInk`).
- **The signature gradient is for brand moments only**: splash, the Shop's hero art, the wallet's hero rule and the profile switcher's counts (#2034). It is never used on recurring chrome.
- **A warning is a yellow glyph with neutral words** (`Warning`).
- **Dark mode is not an inversion.** Roles near the contrast line have Increased Contrast values.
- **One theme only** (the owner, 2026-11-02). The Shop's paid accent themes (#1379) are retired.

## Roles

| Role (`BrandTheme`) | Used for | Light | Dark | IC light / dark |
|---|---|---|---|---|
| `primary` → `tint`, `brandText` | interactive glyphs, text buttons, switches, selection | `F37AB4` | `F37AB4` | `B0256A` / `F8ABCF` |
| `primarySolid` → `primaryFill`, `prominentGlassTint` | the prominent fill and the prominent glass's tint | `F37AB4` | `F37AB4` | — |
| `onPrimary` | the label on the fill | `FFFFFF` | `2B0716` | — |
| `primaryPressed` | the pressed fill | `E86AA6` | `E86AA6` | `9C1F5E` / `E86AA6` |
| `primaryContainer` / `onPrimaryContainer` | soft selected grounds | `FDE3EF` / `B8296C` | `3A0A22` / `F8ABCF` | — |
| `counter` | unread marks, the bell's dot | `7C5CF0` | `7C5CF0` | — |
| `accentGradient` | the story ring, the inbox's unread pills | `F37AB4` → `A78BFA` | same | — |
| `secondary` | secondary emphasis | `6852C6` | `A78BFA` | `5C44B7` / `B59EFF` |
| `secondaryContainer` / `onSecondaryContainer` | gem grounds and badges | `EFEEFF` / `6852C6` | `211944` / `A78BFA` | — |
| `entityInk` | `@mentions`, `#hashtags`, links | `645A82` | `AFA3CC` | `4F4669` / `C3B9DD` |
| `likes` | the likes' heart, glyph and coin | `F37AB4` | `F37AB4` | `B0256A` / `F8ABCF` |
| `gem` | the gems | `6852C6` | `A78BFA` | `5C44B7` / `B59EFF` |
| `saveGold` | the saved star | `FFC53D` | `FFC53D` | — |
| `signatureGradient` → `brandGradient` | brand moments | `E0559A` → `7C5CF0` | same | — |
| `loaderTones` | the branded loader's pills | `F37AB4`, `D98AD0`, `A78BFA` | same | — |

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
3. **Check the contrast.** `PaletteTests` and `PaletteThemeTests` measure every role where it is used. Update the values they pin to the new ones.
4. **Update this document's table.**
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
