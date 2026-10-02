#!/usr/bin/env python3
"""Aurora on white with a filled BLUE globe whose edge is the curve; the posts in white, accent, or white→accent.
Writes globe/*.icon and previews/globe.png (light · dark, then home-screen size)."""
import json, shutil, tempfile
from pathlib import Path
from palettes import HERE, srgb, render, magick

PRIMARY, ACCENT = "#2F5BFF", "#FF4FD8"
GLASS = {"shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.4}}
FLAT = {"shadow": {"kind": "none", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.5}}

def posts(image, fill=None):
    l = {"glass": True, "image-name": image, "name": "posts"}
    if fill:
        l["fill"] = {"solid": srgb(fill)}
    return l

VARIANTS = {  # label: posts layer
    "G1 · white posts": posts("posts.svg", "#FFFFFF"),
    "G2 · accent posts": posts("posts.svg", ACCENT),
    "G3 · white-to-accent posts": posts("posts-gradient.svg"),
}

def spec(post_layer):
    return {"fill": {"solid": srgb("#FFFFFF")},
            "groups": [{"layers": [post_layer], **GLASS},
                       {"layers": [{"glass": False, "image-name": "globe.svg", "name": "globe",
                                    "fill": {"solid": srgb(PRIMARY)}}], **FLAT}],
            "supported-platforms": {"squares": "shared"}}

def main():
    out = HERE / "globe"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir()
    tmp = Path(tempfile.mkdtemp()); tiles, small = [], []
    for i, (label, layer) in enumerate(VARIANTS.items()):
        icon = out / f"GlobePosts-Aurora-G{i + 1}.icon"
        shutil.copytree(HERE / "GlobePosts.icon", icon)
        (icon / "icon.json").write_text(json.dumps(spec(layer), indent=2) + "\n")
        for r in ("Default", "Dark"):
            png = tmp / f"{i}-{r}.png"; render(icon, r, png)
            magick(png, "-resize", "300x300", png); tiles.append(png)
            if r == "Default":
                s = tmp / f"{i}-60.png"; magick(png, "-resize", "60x60", s); small.append(s)
    pitch = 2 * 324
    grid = tmp / "grid.png"
    magick("montage", *tiles, "-tile", f"{2 * len(VARIANTS)}x1", "-geometry", "+12+12", "-background", "#d9d9de", grid)
    cmd = [grid, "-gravity", "northwest", "-background", "#ffffff", "-splice", "0x46",
           "-font", "Helvetica-Bold", "-pointsize", "22", "-fill", "#111111"]
    for i, label in enumerate(VARIANTS):
        cmd += ["-annotate", f"+{18 + i * pitch}+12", f"{label}   (light · dark)"]
    magick(*cmd, grid)
    rows = []
    for bg in ("#e9e6e1", "#1c1c1e"):
        row = tmp / f"home-{bg[1:]}.png"
        magick("-size", f"{len(VARIANTS) * pitch}x96", f"xc:{bg}",
               *sum(([s, "-geometry", f"+{294 + i * pitch}+18", "-composite"] for i, s in enumerate(small)), []), row)
        rows.append(row)
    magick(grid, *rows, "-append", HERE / "previews" / "globe.png")
    shutil.rmtree(tmp)

if __name__ == "__main__":
    main()
