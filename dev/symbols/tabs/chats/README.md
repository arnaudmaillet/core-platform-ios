# core.chats: custom SF Symbols

Four custom SF Symbols, in the same template format as the app's `Symbols.xcassets` (#1128 / #1184) and the `core.square.play` set:

| Symbol | Layers |
|---|---|
| `core.chats` | 1: two bubbles |
| `core.chats.fill` | 1: front bubble filled, back bubble outlined |
| `core.chats.badge` | 2: two bubbles, notification badge |
| `core.chats.badge.fill` | 2: filled front bubble + outlined back bubble, notification badge |

## The art

- Based on **Phosphor `chats-teardrop`** (2.1.1, MIT, see `source/PHOSPHOR-LICENSE`), rebuilt from its geometry: r 80 bubbles, 16 stroke, 16 tail corner.
- **Mirrored**: the whole (front) bubble is on the right and higher, so the badge sits on its corner without touching the back bubble.
- **Bubbles closer**: the back bubble sits at 65 % of Phosphor's offset (`previews/spacing-options.png` shows 100 / 80 / 65 / 50 %).
- **Badge**: on the 45° point of the front bubble's stroke, with the same proportions as `core.square.play.badge` (radius 29, gap 10.7 on the 256 grid). The cut ends of the bubble are round.
- **Scale**: Phosphor's usual 0.4 on the S scale, so the stroke matches the rest of the set. The glyph is 80.6 units wide, which is a little wider than the square set's 70.4.
- **No jumps**: all four variants are placed by the plain icon's box, so adding the badge or filling the bubble never moves anything.

## Two colours in UIKit

Layer 0 (bubbles) is `hierarchical-0:primary`, layer 1 (badge) is `hierarchical-1:secondary`:

```swift
let config = UIImage.SymbolConfiguration(paletteColors: [primaryColor, accentColor])
let image = UIImage(named: "core.chats.badge", in: .module, with: config)
```

- **Palette**: the bubbles take the first colour, the badge takes the second.
- **Monochrome**: both layers take the tint.
- **Hierarchical**: the badge is drawn at the secondary opacity.
- **Multicolor**: bubbles = tint, badge = system red.

## Verified

`actool` compiles all four as vector glyphs. AppKit renders them with palette, hierarchical and bold configurations (`previews/rendered-palette-hierarchical-bold.png`).

## Known limits

- **One outline, three masters**, as in the rest of the set: the stroke does not thicken with `.bold`.
- No Draw-On annotations.

## Regenerate

```bash
cd source && swift gen-chats.swift template-head.svg .. /tmp
```
