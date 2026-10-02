#!/usr/bin/env python3
"""Aurora on a WHITE background: four ways to share blue and magenta between the posts and the horizon.
Writes aurora/*.icon and previews/aurora-white.png (light · dark, then home-screen size)."""
import json, shutil, tempfile
from pathlib import Path
from palettes import HERE, srgb, render, magick

PRIMARY, ACCENT = "#2F5BFF", "#FF4FD8"
GLASS = {"shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.4}}
FLAT = {"shadow": {"kind": "none", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.5}}
DIAGONAL = {"start": {"x": 0.2, "y": 0.2}, "stop": {"x": 0.9, "y": 0.9}}

def solid(hex_):
    return {"solid": srgb(hex_)}

def gradient(a, b):
    return {"linear-gradient": [srgb(a), srgb(b)], "orientation": DIAGONAL}

def layer(image, fill, glass=True, opacity=None):
    l = {"glass": glass, "image-name": image, "name": image.removesuffix(".svg"), "fill": fill}
    if opacity is not None:
        l["opacity"] = opacity
    return l

VARIANTS = {
    # name: (post layers, horizon fill)
    "W1 · blue posts, magenta horizon": ([layer("posts.svg", solid(PRIMARY))], solid(ACCENT)),
    "W2 · one magenta post, blue horizon": ([layer("post-small.svg", solid(ACCENT)),
                                            layer("posts-main.svg", solid(PRIMARY))], solid(PRIMARY)),
    "W3 · blue-to-magenta posts, blue horizon": ([layer("posts.svg", gradient(PRIMARY, ACCENT))], solid(PRIMARY)),
    "W4 · blue posts, blue-to-magenta horizon": ([layer("posts.svg", solid(PRIMARY))], gradient(PRIMARY, ACCENT)),
}

def spec(posts, horizon):
    return {"fill": solid("#FFFFFF"),
            "groups": [{"layers": posts, **GLASS},
                       {"layers": [layer("horizon.svg", horizon, glass=False)], **FLAT}],
            "supported-platforms": {"squares": "shared"}}

def main():
    out = HERE / "aurora"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir()
    tmp = Path(tempfile.mkdtemp()); tiles, small = [], []
    for i, (label, (posts, horizon)) in enumerate(VARIANTS.items()):
        icon = out / f"GlobePosts-Aurora-W{i + 1}.icon"
        shutil.copytree(HERE / "GlobePosts.icon", icon)
        (icon / "icon.json").write_text(json.dumps(spec(posts, horizon), indent=2) + "\n")
        for r in ("Default", "Dark"):
            png = tmp / f"{i}-{r}.png"; render(icon, r, png)
            magick(png, "-resize", "260x260", png); tiles.append(png)
            if r == "Default":
                s = tmp / f"{i}-60.png"; magick(png, "-resize", "60x60", s); small.append(s)
    grid = tmp / "grid.png"
    magick("montage", *tiles, "-tile", "8x1", "-geometry", "+12+12", "-background", "#d9d9de", grid)
    cmd = [grid, "-gravity", "northwest", "-background", "#ffffff", "-splice", "0x46",
           "-font", "Helvetica-Bold", "-pointsize", "21", "-fill", "#111111"]
    for i, label in enumerate(VARIANTS):
        cmd += ["-annotate", f"+{18 + i * 568}+12", label]
    magick(*cmd, grid)
    width = 4 * 568
    rows = []
    for bg in ("#e9e6e1", "#1c1c1e"):
        row = tmp / f"home-{bg[1:]}.png"
        magick("-size", f"{width}x96", f"xc:{bg}",
               *sum(([s, "-geometry", f"+{254 + i * 568}+18", "-composite"] for i, s in enumerate(small)), []), row)
        rows.append(row)
    magick(grid, *rows, "-append", HERE / "previews" / "aurora-white.png")
    shutil.rmtree(tmp)

if __name__ == "__main__":
    main()
