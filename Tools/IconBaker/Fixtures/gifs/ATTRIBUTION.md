# Bench icons — attribution and why these files

Real animated GIFs, used ONLY by the DEBUG `-icon-bench` instrument (`wire=realGIF`).

**All CC0**, from Wikimedia Commons — deliberately, because resources under
`App/Resources/` ship in RELEASE builds too even though the code reading them is
`#if DEBUG`. CC0 carries no attribution obligation, so nothing here creates one.
This table exists for provenance, not because a licence demands it.

| file | px | frames | loop | source |
|---|---|---|---|---|
| `animated_asd_laugh_icon.gif` | 22x23 | 2 | 0.18s | [Commons](https://commons.wikimedia.org/wiki/File:Animated_asd_laugh_icon.gif) |
| `animated_asd_laugh_icon_2.gif` | 22x23 | 2 | 0.18s | [Commons](https://commons.wikimedia.org/wiki/File:Animated_asd_laugh_icon_2.gif) |
| `animated_emoticon_blush.gif` | 15x15 | 13 | 16.10s | [Commons](https://commons.wikimedia.org/wiki/File:Animated_emoticon_blush.gif) |
| `conan_death_icons_animated.gif` | 221x134 | 28 | 56.00s | [Commons](https://commons.wikimedia.org/wiki/File:Conan_death_icons_animated.gif) |
| `iso_7000_2837_animated.gif` | 300x300 | 3 | 1.20s | [Commons](https://commons.wikimedia.org/wiki/File:ISO_7000-2837_-_Animated.gif) |

## Why real files, when the instrument can synthesise its own

Synthetic artwork is one frame count and one frame step BY CONSTRUCTION, and that
hid four properties every real file has:

- **Frame counts run 2 to 28**, not a fixed 12.
- **Delays VARY inside one file** (0.2s / 1.2s / 2.5s in the same GIF) — the case
  `FrameTimeline` resampling exists for, and which synthetic art could never reach.
- **Loops run 0.18s to 56s.** Against the 24-frame cap the long ones compress time
  hard: a 56s loop replayed in ~2s is visibly wrong CONTENT, not a slow icon.
- **Some sources are SMALLER than the target** (15x15 against a 132px disc), so they
  are magnified and blurred. An ingest spec has to reject those.

And the finding that mattered most: five files produce **three different frame steps**
(`steps=3` in the bench report, against `steps=1` for synthetic art). The shared-clock
optimisation assumes every icon changes on ONE grid. Honouring each file's own timing
breaks that, and `presented_fps` then swings between runs purely on which marker the
probe happens to watch. That is why `dev/issues/BACKEND_ANIMATED_PIN_ICONS.md`
mandates a single `frame_ms` from a fixed ladder rather than trusting the container.
