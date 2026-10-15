# core.paperplane: custom SF Symbols

Four custom SF Symbols, in the same template format as the app's `Symbols.xcassets` (#1128 / #1184), `core.square.play` and `core.chats`:

| Symbol | Layers |
|---|---|
| `core.paperplane` | 1: outline |
| `core.paperplane.fill` | 1: filled, fold line knocked out |
| `core.paperplane.badge` | 2: outline, notification badge |
| `core.paperplane.badge.fill` | 2: filled plane, notification badge |

## The art

- **Phosphor `paper-plane-tilt`** (2.1.1, MIT, see `source/PHOSPHOR-LICENSE`). `previews/phosphor-options.png` shows the three Phosphor planes.
- **Scale**: Phosphor's usual 0.4 on the S scale, so the stroke matches the rest of the set.
- **No jumps**: every variant is placed by the outline's box, so filling the plane or adding the badge never moves it.
- **Badge**: centred on the nose's stroke (the nose is an arc of r 16 around its inner corner), the same final size and gap as `core.chats.badge` and `core.square.play.badge`. The cut ends are round.

## Size

Phosphor's plane fills its square, so at the set's usual scale it looked larger than `core.chats` and `core.square.play`. It is shrunk by `fit` = 0.87 (78.8 units wide, against 80.6 and 70.4). The outline is then thickened back on the grid, so the stroke still matches the rest of the set (6.4 on the S scale). `previews/rendered-beside-chats-and-square.png` shows them side by side.

## UIKit

Layer 0 (plane) is `hierarchical-0:primary`, layer 1 (badge) is `hierarchical-1:secondary`:

```swift
let config = UIImage.SymbolConfiguration(paletteColors: [primaryColor, accentColor])
let image = UIImage(named: "core.paperplane.badge", in: .module, with: config)
```

## Verified

`actool` compiles all four as vector glyphs. AppKit renders them with palette, hierarchical and bold configurations.

## Known limits

- **One outline, three masters**: the stroke does not thicken with `.bold`.
- No Draw-On annotations.

## Regenerate

```bash
cd source && swift gen-paperplane.swift template-head.svg .. /tmp
```
