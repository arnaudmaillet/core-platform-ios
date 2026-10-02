#!/usr/bin/env python3
"""White background, globe in a radial primary/accent gradient from its centre (bottom, a little right),
posts in plain white or in white liquid glass. Writes liquid/*.icon and previews/liquid.png."""
import json, shutil, tempfile
from pathlib import Path
from palettes import HERE, srgb, render, magick

FLAT = {"shadow": {"kind": "none", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.5}}
WHITE = {"layers": [{"glass": True, "image-name": "posts.svg", "name": "posts",
                     "fill": {"solid": srgb("#FFFFFF")}}],
         "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.4}}
# Clear glass: the posts let the globe through, frosted, each lit on its own with a specular rim
LIQUID = {"layers": [{"glass": True, "image-name": "posts.svg", "name": "posts", "opacity": 0.75,
                      "fill": {"solid": srgb("#FFFFFF")}}],
          "blur-material": 0.6, "lighting": "individual", "specular": True,
          "shadow": {"kind": "neutral", "opacity": 0.35}, "translucency": {"enabled": True, "value": 0.6}}

VARIANTS = {  # label: (globe asset, posts group)
    "L1 · magenta core, white posts": ("globe-accent-core.svg", WHITE),
    "L2 · magenta core, liquid glass": ("globe-accent-core.svg", LIQUID),
    "L3 · blue core, white posts": ("globe-blue-core.svg", WHITE),
    "L4 · blue core, liquid glass": ("globe-blue-core.svg", LIQUID),
}

def spec(globe, posts):
    return {"fill": {"solid": srgb("#FFFFFF")},
            "groups": [posts, {"layers": [{"glass": False, "image-name": globe, "name": "globe"}], **FLAT}],
            "supported-platforms": {"squares": "shared"}}

def main():
    out = HERE / "liquid"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir()
    tmp = Path(tempfile.mkdtemp()); light, dark, small = [], [], []
    for i, (label, (globe, posts)) in enumerate(VARIANTS.items()):
        icon = out / f"GlobePosts-Aurora-L{i + 1}.icon"
        shutil.copytree(HERE / "GlobePosts.icon", icon)
        (icon / "icon.json").write_text(json.dumps(spec(globe, posts), indent=2) + "\n")
        for r, bucket in (("Default", light), ("Dark", dark)):
            png = tmp / f"{i}-{r}.png"; render(icon, r, png)
            magick(png, "-resize", "380x380", png); bucket.append(png)
        s = tmp / f"{i}-60.png"; magick(light[-1], "-resize", "60x60", s); small.append(s)
    pitch = 404
    rows = []
    for name, tiles in (("light", light), ("dark", dark)):
        row = tmp / f"{name}.png"
        magick("montage", *tiles, "-tile", f"{len(tiles)}x1", "-geometry", "+12+12", "-background", "#d9d9de", row)
        rows.append(row)
    head = tmp / "head.png"
    cmd = ["-size", f"{len(VARIANTS) * pitch}x44", "xc:#ffffff", "-font", "Helvetica-Bold", "-pointsize", "22",
           "-fill", "#111111", "-gravity", "northwest"]
    for i, label in enumerate(VARIANTS):
        cmd += ["-annotate", f"+{18 + i * pitch}+12", label]
    magick(*cmd, head)
    homes = []
    for bg in ("#e9e6e1", "#1c1c1e"):
        h = tmp / f"home-{bg[1:]}.png"
        magick("-size", f"{len(VARIANTS) * pitch}x96", f"xc:{bg}",
               *sum(([s, "-geometry", f"+{172 + i * pitch}+18", "-composite"] for i, s in enumerate(small)), []), h)
        homes.append(h)
    magick(head, *rows, *homes, "-append", HERE / "previews" / "liquid.png")
    shutil.rmtree(tmp)

if __name__ == "__main__":
    main()
