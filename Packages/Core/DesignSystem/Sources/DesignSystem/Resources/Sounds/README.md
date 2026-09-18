# Sounds

Every sound the app makes for itself lives here — not a clip's own audio, which
belongs to `MediaPlayback`.

## pop.caf

The tick an element makes as it arrives: the editing band's rows, one per
element, 40ms apart (`BandPop`).

| | |
|---|---|
| Source | Kenney, *Interface Sounds* 1.0 — <https://kenney.nl/assets/interface-sounds> |
| Licence | **CC0 1.0** (public domain dedication; attribution is not required, and is given here anyway) |
| Original | `Audio/drop_001.ogg` from `kenney_interface-sounds.zip` (834 KB, sha256 `f2193d072726d6758a5f7871b2dcc54dcce0d5c35c6f0a62f92549b327c81232`) |
| This file | trimmed to its audible 70ms with a 5ms fade, decoded to 16-bit mono PCM at 44.1kHz |

⚠️ **CHOSEN BY MEASUREMENT, NOT BY NAME.** Twenty-four candidates were decoded
and read for length, peak and dominant pitch, then the three shortest plausible
ones were rendered as the app will actually play them — nine of them, 40ms
apart, which is a filter row opening. Anything whose audible tail runs past the
stagger smears the row into one noise:

| candidate | audible | ~pitch | why not |
|---|---|---|---|
| `click_005` | 7ms | 140Hz | a dull tap; the crispest in sequence, but barely a "pop" |
| **`drop_001`** | **53ms** | **1500Hz** | **the bubble timbre the pop is named after, overlapping by about a third — a ripple, not a queue** |
| `select_007` | 45ms | 983Hz | brighter, and closer to a UI "select" than to an element landing |

Swapping it is one file: keep the name, keep the licence note honest.
