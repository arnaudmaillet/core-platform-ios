# App icon explorations

The shipped icon is `App/Resources/AppIcon.icon` (variant **L2**). Everything here is the working material behind it, kept so a direction can be revisited.

- `GlobePosts.icon` — the master: every layer asset (globe, horizon, posts) the variants pick from.
- `liquid/` — the final round on a white background: a globe in a radial Aurora gradient whose core sits below the icon, with white posts (L1, L3) or white liquid-glass posts (L2, L4). L1/L2 have a magenta core, L3/L4 a blue one.
- `globe/`, `aurora/` — earlier rounds (flat blue globe; horizon line only).
- `palettes/` — the icon in the palettes kept aside: Aurora (current), Electric, Solar, Midnight.

Each `*.py` script rewrites its folder and renders `previews/*.png` (git-ignored) with the `ictool` inside Icon Composer:

```bash
./liquid.py && open previews/liquid.png
```

⚠️ `/Applications/Xcode.app/Contents/Developer/usr/bin/ictool` cannot export images; the scripts use `Icon Composer.app/Contents/Executables/ictool`.
