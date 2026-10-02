# App icon explorations

The shipped icon is `App/Resources/AppIcon.icon`: a magic wand bent into an exact half circle (hollow ends, solid band in the middle) with three bubbles, on an Aurora-blue background. It was composed by hand in Icon Composer from the SVGs in `wand/`. Everything here is the working material behind it, kept so a direction can be revisited.

- `wand/` — the layers of the shipped icon, each on the same 1024 canvas so they stack in place: `wand.svg`, `bubble-large.svg`, `bubble-medium.svg`, `bubble-small.svg`. `v1-wand-sparkles-circles.svg` is the first take (a gently bent wand after the composition of SF Symbol `wand.and.sparkles.inverse`, its sparkles redrawn as circles). `./wand.py half` rebuilds `wand.svg`; pass a number instead to bow the wand by that many points.
- The globe icon that shipped first (#363, superseded):
  - `GlobePosts.icon` — the master: every layer asset (globe, horizon, posts) the variants pick from.
  - `liquid/` — the last round on a white background: a globe in a radial Aurora gradient whose core sits below the icon, with white posts (L1, L3) or white liquid-glass posts (L2, L4). L1/L2 have a magenta core, L3/L4 a blue one. L2 is the one that shipped.
  - `globe/`, `aurora/` — earlier rounds (flat blue globe; horizon line only).
  - `palettes/` — that icon in the palettes kept aside: Aurora (current), Electric, Solar, Midnight.

The globe scripts rewrite their folder and render `previews/*.png` (git-ignored) with the `ictool` inside Icon Composer:

```bash
./liquid.py && open previews/liquid.png
```

⚠️ `/Applications/Xcode.app/Contents/Developer/usr/bin/ictool` cannot export images; the scripts use `Icon Composer.app/Contents/Executables/ictool`.

⚠️ SF Symbols may not be used in app icons (Apple's licence). The wand is redrawn from scratch and deliberately departs from the symbol (half-circle shaft, circles instead of sparkles) — keep it that way.
