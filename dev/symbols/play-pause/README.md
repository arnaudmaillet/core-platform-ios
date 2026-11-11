# core.play.fill and core.pause.fill: the owner's play and pause (#2276)

Every play and pause in the app is drawn from the owner's two drawings (`source/play-owner.svg`, `source/pause-owner.svg`, 64 grid, one filled path each). They are custom SF Symbols, read through `AppSymbol`, and one swap moves between them (`PlayPauseGlyph`, DesignSystem).

| Symbol | `AppSymbol` | VoiceOver | Drawing |
|---|---|---|---|
| `core.play.fill` | `.play` | "Play" | the owner's rounded triangle, its full back |
| `core.pause.fill` | `.pause` | "Pause" | the owner's two tall ovals, **as drawn** |
| `core.play.circle.fill` | `.playCircle` | "Play" | `play.circle.fill`'s disc, the owner's play knocked out of it |
| `core.pause.fill.wide` | none (previews only) | | the widened pause the owner may pick (below) |

## How they are drawn (`source/gen-play-pause.swift`)
1. **Traced as drawn.** The owner's paths are parsed as they are; no point moves.
2. **One box for both.**
   - The box is the pause's 48-unit height (8 to 56 on the grid). It is scaled (×1.38) to `play.fill`'s ink height, 66.25 units on the template (100 pt, small scale). The play (47.76 tall) stands centred in the same box.
   - Both images are **74.65 units wide**, with the same margins and the same line, so a swap never moves the glyph (`previews/swap-box-overlay.png`). `AppSymbolTests.thePlayAndThePauseShareOneBox` checks this.
   - Their middle stands 35.6 units above the baseline: `play.fill`'s ink sits at 35.9, `pause.fill`'s at 35.4, the cap height's middle at 35.23. So the alignment insets match the system's, and every site keeps its height (`AppSymbolSizeTests`).
   - The box is wider than `play.fill`'s (70) by 4.65 units: the play's optical shift (below) and the set's 4-unit side margin (#1566). At UIKit's default (medium) scale that is about 0.75 pt wider at 13 pt and 3.2 pt at 56 pt. Every site centres the glyph, so nothing moves.
3. **The play's optical centre.** In a disc, SF centres its play neither on the triangle's box (its heavy back would look too far left) nor on its centroid (its point would look too far right).
   - Measured on `play.circle.fill`: the disc's middle is 0.337 of the way from the knocked-out play's centroid to its box's middle (`source/measure-sf.swift`).
   - The owner's play follows the same rule, measured on its own shape: centroid at x 28.75, box middle at 32.05. Its optical centre is therefore at 29.86, so it moves 2.14 units right of the box's centre (64 grid).
   - Its image is centred there, so any view that centres it (the paused clip's mark, the voice button, a disc) shows it centred the way SF centres its play. `previews/optical-centre.png` shows this.
   - `play.fill`'s own image uses 0.524 instead, a box drawn for text. #2276 asks for a play that looks centred on a picture or in a disc.
4. **`core.play.circle.fill`** is `play.circle.fill`'s disc (78.75 across, in a 93-wide image, its middle 35.1 above the baseline) with the owner's play knocked out. The play is as tall as SF's knocked-out play (31.75) and its optical centre is on the disc's middle. The conversation's video keeps its look: a white disc at 0.9 with the picture showing through the play.
5. **The template.** It uses the set's head and three masters with one outline. Like the rest of the set, the glyphs ignore `.semibold`: the sites that ask for it (the sound sheet, the timeline, the paused mark) get the same shape at the size they ask for.

## ⚠️ The pause's gap: the owner picks
On the grid, the drawn ovals stand 2.42 units apart, about 6 % of the glyph's width (SF's `pause.fill` leaves about a quarter). At 13 pt that gap is about 0.6 pt, one or two pixels, and it reads as one blob.

- **Shipped: the pause as drawn** (`core.pause.fill`).
- **Widened** (`core.pause.fill.wide`, `source/Widened.xcassets`, previews only): each oval is narrowed about its **outer** edge (×0.883, 19.58 → 17.29 units). The glyph keeps its width, and the gap opens to **7 units**.

Both are in every comparison below, in the last two columns. To ship the widened one, regenerate with `PAUSE=wide` (see below). The name stays `core.pause.fill`, so no code changes.

## Previews (rendered from the compiled catalogue)
Every glyph is centred in its cell, the way an image view (`.center`) or a button centres it. They are shown at 13, 16, 22 and 56 pt, at 3×. The columns are SF ▶︎, the owner's ▶︎, SF ❚❚, the owner's ❚❚ as drawn, and the owner's ❚❚ widened.

| | |
|---|---|
| On the voice panel's grey, light (the played ink: the label at 0.7, over the panel at 0.06) | `previews/compare-panel-light.png` |
| On the voice panel's grey, dark (the label at 0.7, over the panel at 0.12) | `previews/compare-panel-dark.png` |
| On a bright picture (white at 0.85, with a shadow, the paused mark's ink) | `previews/compare-picture-bright.png` |
| On a dark picture | `previews/compare-picture-dark.png` |
| The optical centre: `play.circle.fill` and `core.play.circle.fill` at 34 and 72 pt, and both bare plays centred in a circle | `previews/optical-centre.png` |
| Play over pause in their boxes, SF's and the owner's | `previews/swap-box-overlay.png` |
| The generator's flat previews (the glyph in its margins, with the baseline and the cap height) | `previews/core.*.png` |

## The swap (`PlayPauseGlyph`)
There is one swap, and one switch decides each site's motion: `PlayPauseGlyph.swap(for:)`.

| Site | Motion | Why |
|---|---|---|
| The voice panel's button (`VoiceView`) | Replace (`.replace.offUp`, speed 2) | a bare glyph since #2274, not in glass |
| The sound sheet's button (`SoundSheetHeaderView`) | **scale and fade** | in the glass button; Replace stuttered there (the owner, 2026-10-16) |
| The voice composer's chip and take button (`VoiceRecordingStrip`) | Replace | a grey chip and a plain button, no glass |
| The media editor's timeline (`MediaTimelineTrackView`) | Replace | ink with a shadow on the film; was a cut |
| The media editor's flash (`MediaPlaybackFlashView`) | **scale and fade** | its glass capsule; was a cut |

- **Scale and fade:** the old glyph shrinks to 0.4 and fades on a copy, while the new one springs up from 0.4 as it fades in. It is the sound sheet's own swap, moved into DesignSystem.
- **Reduce Motion:** a cross-fade in place, at every site.
- **Unanimated** (off screen, a row filled afresh): a cut.
- A swap that overtakes one in flight starts from where that one had got to. It leaves one glyph when it ends (`PlayPauseGlyphTests`).
- ⚠️ **Replace on the custom symbols is a device check.** If it stutters or cuts on a device, the site moves to `.scaleAndFade` in `swap(for:)`, one line.

## Regenerate
```bash
cd source && swift measure-sf.swift   # the system's numbers, which the generator's constants are
swift gen-play-pause.swift template-head.svg play-owner.svg pause-owner.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews Widened.xcassets
```
To ship the widened pause, prefix the second command with `PAUSE=wide`.

Render the compiled previews (macOS):
```bash
mkdir -p /tmp/pp/Sym.bundle/Contents/Resources
xcrun actool <Symbols.xcassets> source/Widened.xcassets --compile /tmp/pp/Sym.bundle/Contents/Resources \
  --platform macosx --minimum-deployment-target 14.0
# add a minimal Contents/Info.plist (CFBundleIdentifier), then:
swiftc source/render-compiled.swift -o /tmp/pp/render
/tmp/pp/render /tmp/pp/Sym.bundle previews <bright picture> <dark picture>
```
The pictures used are the mock clips `clip-120.jpg` (bright) and `clip-137.jpg` (dark) from `CoreNetworkingMocks/Resources/MockClips`.

## Not done here
- **Simulator screenshots of every site and slowed recordings of each swap** (#2276's acceptance). This change was built without a simulator.
- **The device check of every swap**, the owner's.
- `GlassPlayMark` (DEBUG prototype, `-glass-play-mark`) keeps its own triangle, with `play.fill`'s proportions.
