# core.trash: the owner's bin (#2459)

The owner's bin replaces the system's `trash` and `trash.fill` everywhere. It is traced from the owner's 64 px outline drawing, `source/trash-owner.png`; there is no filled drawing, so the fill is derived.

| Symbol | `AppSymbol` | Replaces | From |
|---|---|---|---|
| `core.trash` | `.trash` | `trash` | the drawing |
| `core.trash.fill` | `.trashFill` | `trash.fill` | derived |

## How it is drawn (`source/gen-trash.swift`)
1. **Symmetric**: the drawing is averaged with its mirror image about the middle of its ink box (x 32), so the outer slots are alike and evenly spaced about the middle one, then traced and set to the set's 6.4 units. The lid, its arched handle, the tapered tub and the slots keep the owner's curves.
2. **The fill, derived**: the lid and the tub solid, the three slots cut out exactly where the outline draws them, and the handle left an open arch over the lid. Same box as the outline, so a swap never moves the bin.
3. **Size: 1.6 units per drawing pixel.** At 12 pt semibold it is 16 pt tall, as `trash` (133 units at 100 pt against 130).

## Previews (`previews/`)
- `sheet.png`: the drawing, both symbols large, beside `trash` / `trash.fill` at 12, 17, 22 and 34 pt and at three weights, light and dark.
- `derived-faces.png`: the derived faces (`core.trash.fill`, `core.mic`, `core.bookmark.slash`) beside the drawn ones, at 17 and 22 pt, light and dark. If the owner rejects a derived face on the device, its sites take the drawn face (the bin's outline, the microphone's fill, the filled bookmark for Unpin).
- `outline-over-fill.png`, `traced-over-outline.png`.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-trash.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
