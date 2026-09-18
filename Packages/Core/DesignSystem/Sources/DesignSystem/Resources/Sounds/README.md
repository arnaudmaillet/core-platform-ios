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

## tap.caf

The tick a control makes when a press on it turns out to be a tap: every
button of the editing band's tools, and the finalisation strip's thumbnails
(`PressFeedback`). Played on the release, never on the touch-down — a scroll
begins with a finger landing on a chip, and must not click.

| | |
|---|---|
| Source | Kenney, *Interface Sounds* 1.0 — <https://kenney.nl/assets/interface-sounds> |
| Licence | **CC0 1.0** (public domain dedication; attribution is not required, and is given here anyway) |
| Original | `Audio/tick_001.ogg` from `kenney_interface-sounds.zip` (834 KB, sha256 `f2193d072726d6758a5f7871b2dcc54dcce0d5c35c6f0a62f92549b327c81232`) |
| This file | trimmed to 12ms (529 frames) with a 3ms fade from its −43dB point, decoded to 16-bit mono PCM at 44.1kHz |

⚠️ **CHOSEN BY MEASUREMENT, AND AGAINST THE POP.** All hundred files were
decoded to mono 44.1kHz and read for their audible length (onset to the last
2ms window above −40dB of the file's own peak), their −20dB length, and their
dominant pitch (the strongest FFT bin between 80Hz and 8kHz over the audible
part). Two rules decided it. It fires on EVERY tap, so it has to be over long
before a fast finger's next tap (~80ms): everything over 25ms audible was out,
which leaves ten, three of them glitches. And it must not sound like
`pop.caf` — measured the same way, `drop_001` is 54ms audible with its energy
at 2056Hz, a pitched bubble — because a tap that sounded like the pop would
announce an arrival that never came. (The pop's table above read its pitch at
1500Hz and `click_005`'s at 140Hz through a different window; every number
below, the pop's included, is from the one script, which is what makes them
comparable.)

| candidate | audible | ~pitch | why not |
|---|---|---|---|
| `click_003` | 8ms | 2272Hz | the right length, but its pitch is under two semitones from the pop's: heard as a smaller pop |
| `click_005` | 8ms | 86Hz | its energy is a thud at 86Hz, below what a phone's own speaker reproduces (they roll off in the low hundreds) — on the device it would be mostly silence |
| `click_004` | 8ms | 151Hz | the same thud, with a hiss at 7.2kHz and nothing in between |
| `select_001` | 34ms | 2218Hz | three times longer, and the pop's pitch again |
| `tick_002` | 22ms | 797Hz | the same tick as the winner with twice the ring, which is what a run of taps smears on |
| **`tick_001`** | **10ms** | **797Hz** | **the shortest sound in the pack whose body is both well away from the pop — an octave and a third below it — and well inside what a phone's speaker plays, with a 4–5.6kHz click on top; over in a fifth of the pop's length** |

It plays through the same pool as the pop, at the same 0.35 — measured, its
integrated energy is 5dB under the pop's, which is the right side of the pop
for something that happens on every tap.
