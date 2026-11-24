# core.bookmark: a conversation's pin (#2459)

The owner's bookmark replaces the pin on **conversations only**: pinning a conversation to the top of the inbox. **The map's pins don't change**: the pins that put a place or a profile in the map's favourites (`MapSubFilterMenu`'s Unpin, the profile's "Map Dock", `MapProfilePinning`) keep `pin` / `pin.slash`. The words stay "Pin" / "Unpin" / "Pinned". It is traced from the owner's two 64 px drawings, `source/bookmark-owner.png` (outline) and `source/bookmark-fill-owner.png` (filled).

| Symbol | `AppSymbol` | Replaces (conversations) | From |
|---|---|---|---|
| `core.bookmark` | `.bookmark` | `pin` | the drawing |
| `core.bookmark.fill` | `.bookmarkFill` | `pin.fill` | the drawing |
| `core.bookmark.slash` | `.bookmarkSlash` | `pin.slash` | derived |

## How it is drawn (`source/gen-bookmark.swift`)
1. **Symmetric**: the outline drawing is averaged with its mirror image about x 32, traced and set to the set's 6.4 units: the domed top, the straight sides and the soft notch.
2. **The fill is the outline's silhouette.** The two drawings share their ink box; where they disagree, the outline wins. A swap never moves the bookmark.
3. **The slash is the bell's** (`core.bell.slash`, #2457): 45°, the set's stroke, round caps, as long as the bell's where the box allows, centred on the bookmark's box, crossing over the contour as on the bell's outline.
4. **Size: 1.72 units per drawing pixel.** At 12 pt semibold it is 16 pt tall against `pin`'s 17 (130 units at 100 pt against 136): within the size guard, and no larger, since the bookmark is twice as wide as the pin.

## Previews (`previews/`)
- `sheet.png`: the drawings, the three symbols large, beside `pin`, `pin.fill` and `pin.slash` at 12, 17, 22 and 34 pt and at three weights, light and dark.
- `derived-faces.png`: the derived faces (`core.trash.fill`, `core.mic`, `core.bookmark.slash`) beside the drawn ones, at 17 and 22 pt, light and dark. If the owner rejects a derived face on the device, its sites take the drawn face (the bin's outline, the microphone's fill, the filled bookmark for Unpin).
- `traced-over-*.png`.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-bookmark.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
