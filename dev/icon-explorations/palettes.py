#!/usr/bin/env python3
"""Writes one GlobePosts .icon per palette, renders it with ictool and lays out previews/palettes.png."""
import json, shutil, subprocess, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

# name, tagline, primary (icon background), deep, accent, ink (dark surface), paper (light surface), disc colour
PALETTES = [
    ("Electric", "violet + lime, loud and Gen Z", "#6C3BFF", "#3E1BB8", "#C8FF3D", "#0F0A1F", "#F6F3FF", None),
    ("Aurora",   "electric blue + magenta, nightlife and media", "#2F5BFF", "#1A2FB0", "#FF4FD8", "#0B0F24", "#F3F5FF", None),
    ("Solar",    "orange + blue, warm and energetic", "#FF6A1A", "#D9430B", "#2E7BFF", "#1A0E07", "#FFF6EF", None),
    ("Midnight", "deep navy + mint, a dark icon that glows", "#151838", "#0A0C22", "#3DF5A6", "#07081A", "#F4F5FA", "#3DF5A6"),
]
POINTS, GEMS = "#FF3B30", "#00C0E8"  # PointsSymbol.tint (.systemRed) and GemSymbol.tint (.systemCyan), for clash checking

def srgb(hex_):
    r, g, b = (int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"

def write_icon(dest, primary, disc):
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(HERE / "GlobePosts.icon", dest)
    spec = json.loads((dest / "icon.json").read_text())
    spec["fill"] = {"automatic-gradient": srgb(primary)}
    if disc:
        spec["groups"][0]["layers"][0]["fill"] = {"automatic-gradient": srgb(disc)}
    (dest / "icon.json").write_text(json.dumps(spec, indent=2) + "\n")

def render(icon, rendition, out, size=1024):
    subprocess.run([ICTOOL, str(icon), "--export-image", "--output-file", str(out), "--platform", "iOS",
                    "--rendition", rendition, "--width", str(size), "--height", str(size), "--scale", "1"],
                   check=True, capture_output=True)

def magick(*args):
    subprocess.run(["magick", *map(str, args)], check=True)

def main():
    out_dir, icons = HERE / "previews", HERE / "palettes"
    out_dir.mkdir(exist_ok=True); icons.mkdir(exist_ok=True)
    tmp = Path(tempfile.mkdtemp())
    rows = []
    for name, tagline, primary, deep, accent, ink, paper, disc in PALETTES:
        icon = icons / f"GlobePosts-{name}.icon"
        write_icon(icon, primary, disc)
        tiles = []
        for r in ("Default", "Dark"):
            png = tmp / f"{name}-{r}.png"
            render(icon, r, png)
            magick(png, "-resize", "230x230", png)
            tiles.append(png)
        swatches = []
        for label, hex_ in (("Primary", primary), ("Deep", deep), ("Accent", accent), ("Ink", ink),
                            ("Paper", paper), ("Points ♥", POINTS), ("Gems ◆", GEMS)):
            sw = tmp / f"{name}-{label}.png"
            text = "#111111" if label in ("Paper", "Accent", "Gems ◆") or hex_ in ("#C8FF3D", "#3DF5A6") else "#FFFFFF"
            magick("-size", "150x230", f"xc:{hex_}", "-gravity", "southwest", "-font", "Helvetica-Bold",
                   "-pointsize", "20", "-fill", text, "-annotate", "+14+38", label,
                   "-font", "Helvetica", "-pointsize", "18", "-annotate", "+14+14", hex_.upper(), sw)
            swatches.append(sw)
        row = tmp / f"{name}-row.png"
        magick("montage", *tiles, *swatches, "-tile", "9x1", "-geometry", "+10+10", "-background", "#ffffff", row)
        magick(row, "-gravity", "northwest", "-background", "#ffffff", "-splice", "0x52", "-font", "Helvetica-Bold",
               "-pointsize", "30", "-fill", "#111111", "-annotate", "+14+12", f"{name}",
               "-font", "Helvetica", "-pointsize", "24", "-fill", "#666666", "-annotate", f"+{40 + 19 * len(name)}+16",
               f"— {tagline}   (icon: light · dark)", row)
        rows.append(row)
    magick(*rows, "-background", "#ffffff", "-append", "-bordercolor", "#ffffff", "-border", "16", out_dir / "palettes.png")
    shutil.rmtree(tmp)

if __name__ == "__main__":
    main()
