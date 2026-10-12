#!/usr/bin/env python3
"""Re-encodes EmoteKit's bundled emote seeds (#971) as lossless WebP.

    Scripts/compress-emote-seeds.py

The seeds (`EmoteSeeds`) are written by `EmoteSeedGenerator`, a test that
bakes each seeded emote with the engine's own bake and writes it in the disk
cache's format (`EmoteSheetFile`): a 4-byte big-endian length, the JSON cut,
then a PNG. ImageIO can decode WebP but not encode it, so this step swaps each
PNG for a LOSSLESS WebP of the same pixels: about half the bytes (3.9 MB of
PNG, 1.8 MB of WebP for the twenty), and the app's decoder
(`CGImageSourceCreateWithData`) reads either. Lossless, so a seed is still
exactly the sheet the engine would bake.

Idempotent: a seed already in WebP is left alone.

Requires `cwebp` (`brew install webp`).
"""

import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SEEDS = Path(__file__).resolve().parent.parent / "Packages/Core/EmoteKit/Sources/EmoteKit/Resources/Seeds"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def main() -> int:
    if shutil.which("cwebp") is None:
        print("cwebp not found: brew install webp", file=sys.stderr)
        return 1
    files = sorted(SEEDS.glob("*.emotesheet"))
    if not files:
        print(f"no seeds in {SEEDS}", file=sys.stderr)
        return 1
    before = after = 0
    with tempfile.TemporaryDirectory() as scratch:
        for seed in files:
            data = seed.read_bytes()
            (length,) = struct.unpack(">I", data[:4])
            header, image = data[: 4 + length], data[4 + length :]
            before += len(data)
            if image.startswith(PNG_SIGNATURE):
                png = Path(scratch) / "sheet.png"
                webp = Path(scratch) / "sheet.webp"
                png.write_bytes(image)
                # -exact keeps the colour under transparent pixels, so the
                # decoded sheet is the baked one bit for bit.
                subprocess.run(
                    ["cwebp", "-quiet", "-lossless", "-exact", "-z", "9", str(png), "-o", str(webp)],
                    check=True,
                )
                data = header + webp.read_bytes()
                seed.write_bytes(data)
            after += len(data)
    print(f"{len(files)} seeds: {before:,} -> {after:,} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
