#!/usr/bin/env python3
"""Imports the round flags the map wears, one per country of `CountryAtlas`.

    Scripts/import-circle-flags.py

Source: HatScripts/circle-flags (MIT), https://github.com/HatScripts/circle-flags,
pinned at tag `TAG` (commit `COMMIT`). Only the flags of the countries in
`Packages/Features/Maps/Sources/Maps/Resources/countries.json` are fetched.

Writes `Packages/Features/Maps/Sources/Maps/Resources/Flags/Flags.xcassets`:
one image set per country, named by its ISO 3166-1 alpha-2 code ("FR"), with
the SVG rasterised by `rsvg-convert` (librsvg) at @2x and @3x of `POINT_SIZE`
— the largest size the map draws a flag (an empty country's disc); the corner
badge draws the same picture at half that. Pre-rendered, so the app never
rasterises an SVG at run time, and an asset catalog, so App Thinning ships one
scale per device.

A country the set has no flag for is listed and skipped; the app falls back to
its emoji (`FlagPalette`). Also refreshes the set's LICENSE next to the catalog.

Requires `rsvg-convert` (`brew install librsvg`).
"""

import json
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Packages/Features/Maps/Sources/Maps/Resources"
ATLAS = RESOURCES / "countries.json"
OUT = RESOURCES / "Flags"
CATALOG = OUT / "Flags.xcassets"
TAG = "v2.8.0"
COMMIT = "66333d058b553461223de5ec3b6e21ff846bcd5a"
RAW = f"https://raw.githubusercontent.com/HatScripts/circle-flags/{COMMIT}"
POINT_SIZE = 40
SCALES = (2, 3)

LICENSE_HEADER = f"""The round flags in Flags.xcassets are from circle-flags by HatScripts,
https://github.com/HatScripts/circle-flags ({TAG}, commit {COMMIT}),
rasterised to PNG by Scripts/import-circle-flags.py. No other changes were
made to the artwork. They are distributed under the MIT License below.

"""


def fetch(path):
    with urllib.request.urlopen(f"{RAW}/{path}") as response:
        return response.read()


def main():
    if shutil.which("rsvg-convert") is None:
        sys.exit("rsvg-convert not found: brew install librsvg")
    codes = sorted(country["code"] for country in json.loads(ATLAS.read_text()))
    if CATALOG.exists():
        shutil.rmtree(CATALOG)
    CATALOG.mkdir(parents=True)
    (CATALOG / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )
    (OUT / "LICENSE").write_text(LICENSE_HEADER + fetch("LICENSE.md").decode())
    missing = []
    with tempfile.TemporaryDirectory() as scratch:
        for code in codes:
            try:
                svg = fetch(f"flags/{code.lower()}.svg")
                # A flag shared by several codes is a symlink in the repository
                # (Heard Island → Australia), served raw as the target's name.
                if not svg.lstrip().startswith(b"<"):
                    svg = fetch(f"flags/{svg.decode().strip()}")
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
                missing.append(code)
                continue
            source = Path(scratch) / f"{code}.svg"
            source.write_bytes(svg)
            imageset = CATALOG / f"{code}.imageset"
            imageset.mkdir()
            images = [{"idiom": "universal", "scale": "1x"}]
            for scale in SCALES:
                name = f"{code}@{scale}x.png"
                side = str(POINT_SIZE * scale)
                subprocess.run(
                    ["rsvg-convert", "-w", side, "-h", side, "-o", str(imageset / name), str(source)],
                    check=True,
                )
                images.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
            (imageset / "Contents.json").write_text(
                json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
            )
    print(f"{len(codes) - len(missing)} flags written to {CATALOG.relative_to(ROOT)}")
    if missing:
        print("no flag (emoji fallback): " + " ".join(missing))


if __name__ == "__main__":
    main()
