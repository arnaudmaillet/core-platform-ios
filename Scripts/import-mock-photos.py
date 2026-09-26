#!/usr/bin/env python3
"""Imports a folder of photo galleries as the mock BFF's picture corpus.

    Scripts/import-mock-photos.py ~/Downloads/photos

One GALLERY per subfolder that holds `.jpg` files (subfolders with none — the
video-only ones — and `.DS_Store` are ignored). Galleries are numbered
`gallery-1…` in sorted folder-name order and their photos in NATURAL order
(`-2` before `-10`), so ids are stable across runs over the same sources.

Every photo is downscaled so its long side is at most 1440 px (aspect kept),
re-encoded as JPEG quality 82 with `sips`, and stripped of its metadata (EXIF,
XMP, IPTC, comments — the ICC profile is kept, it is the photo's colour). The
output goes to `Resources/MockPhotos` with `photos.json`, the manifest
`MockPhotoCatalog` reads: one entry per gallery, each listing its photos with
their ENCODED size — the size the dataset declares, because pre-layout crops
to the declared size.

⚠️ The output is committed (no Git LFS here), so the budget is the point:
1440 px is the widest a phone draws a full-bleed photo at 3x on the smallest
axis that matters, and quality 82 is where the artefacts stop showing on a
photograph at that size. The folder is rewritten from scratch on every run.
"""

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/Resources/MockPhotos"
LONG_SIDE = 1440
QUALITY = 82


def natural_key(path: Path):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", path.name)]


def sips_properties(path: Path) -> dict:
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "orientation", str(path)],
                         check=True, capture_output=True, text=True).stdout
    found = dict(re.findall(r"^\s+(\w+): (.+)$", out, re.MULTILINE))
    return {
        "width": int(found["pixelWidth"]),
        "height": int(found["pixelHeight"]),
        "orientation": None if found.get("orientation", "<nil>") == "<nil>" else int(found["orientation"]),
    }


def strip_metadata(data: bytes) -> bytes:
    """Drops every APPn segment but JFIF (APP0) and the ICC profile (APP2),
    and every comment, without touching the compressed image. Lossless: the
    scan data after SOS is copied as is."""
    if data[:2] != b"\xff\xd8":
        raise ValueError("not a JPEG")
    out = bytearray(data[:2])
    position = 2
    while position < len(data):
        if data[position] != 0xFF:
            raise ValueError(f"bad marker at {position}")
        marker = data[position + 1]
        if marker == 0xDA:  # start of scan: the rest is image data
            out += data[position:]
            break
        length = int.from_bytes(data[position + 2:position + 4], "big")
        segment = data[position:position + 2 + length]
        is_app = 0xE0 <= marker <= 0xEF
        keep = not (is_app or marker == 0xFE) or marker == 0xE0 or (
            marker == 0xE2 and segment[4:16] == b"ICC_PROFILE\x00")
        if keep:
            out += segment
        position += 2 + length
    return bytes(out)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = Path(sys.argv[1]).expanduser()
    folders = sorted(d for d in source.iterdir() if d.is_dir() and any(d.glob("*.jpg")))
    if not folders:
        sys.exit(f"no subfolder of {source} holds .jpg files")

    OUT.mkdir(parents=True, exist_ok=True)
    for stale in OUT.iterdir():
        stale.unlink()

    manifest = []
    with tempfile.TemporaryDirectory() as scratch:
        for number, folder in enumerate(folders, start=1):
            gallery_id = f"gallery-{number}"
            photos = []
            for index, photo in enumerate(sorted(folder.glob("*.jpg"), key=natural_key), start=1):
                original = sips_properties(photo)
                # Stripping EXIF drops the orientation tag, so a rotated source
                # would come out on its side. None of these carry one; refuse
                # rather than guess if a later import does.
                if original["orientation"] not in (None, 1):
                    sys.exit(f"{photo}: EXIF orientation {original['orientation']} is not handled")
                photo_id = f"{gallery_id}-{index:02d}"
                encoded = Path(scratch) / f"{photo_id}.jpg"
                resize = ["-Z", str(LONG_SIDE)] if max(original["width"], original["height"]) > LONG_SIDE else []
                subprocess.run(["sips", *resize, "-s", "format", "jpeg", "-s", "formatOptions", str(QUALITY),
                                str(photo), "--out", str(encoded)], check=True, capture_output=True)
                (OUT / encoded.name).write_bytes(strip_metadata(encoded.read_bytes()))
                size = sips_properties(OUT / encoded.name)
                photos.append({"id": photo_id, "file": encoded.name,
                               "width": size["width"], "height": size["height"]})
            manifest.append({"id": gallery_id, "photos": photos})
            dimensions = sorted({f"{p['width']}x{p['height']}" for p in photos})
            print(f"{gallery_id}  {len(photos):2d} photos  {', '.join(dimensions)}  <- {folder.name}")

    (OUT / "photos.json").write_text(json.dumps(manifest, indent=2) + "\n")
    total = sum(p.stat().st_size for p in OUT.iterdir())
    count = sum(len(g["photos"]) for g in manifest)
    print(f"{len(manifest)} galleries, {count} photos, {total / 1_000_000:.1f} MB in {OUT}")


if __name__ == "__main__":
    main()
