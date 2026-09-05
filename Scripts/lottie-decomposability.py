#!/usr/bin/env python3
"""
Answers one question about a Lottie file: can it be shipped as a still plus a
motion track (Ask C in dev/issues/BACKEND_ANIMATED_PIN_ICONS.md), or does it
have to be baked to a sprite sheet (Ask D)?

    Scripts/lottie-decomposability.py path/to/*.lottie path/to/*.json

Why this is a script and not a judgement call: the difference between the two
answers is 9 MB and 217 MB on the map's worst case, and it is decided by
properties buried in a 500 KB JSON that nobody is going to read. It is also the
publish-time guard the backend document asks for — the client cannot make this
call, because by the time it can measure the file it has already paid for it.

WHAT COUNTS AS DECOMPOSABLE

A property is affine when it is a transform: a layer transform (`ks`) or a shape
group transform (`ty: "tr"`) animating scale, rotation, position, anchor, skew
or opacity. Core Animation applies those to a layer for free.

Everything else changes PIXELS and has to be rasterised: path morphs, trim
paths, stroke widths, colours, gradient endpoints.

⚠️ Affine is necessary, not sufficient. Decomposition costs one still PER
ANIMATED LAYER, so an icon with more animated layers than the sheet has frames
is cheaper as a sheet. The threshold is `frame_count` — 24 by contract — and
this script reports the layer count so the comparison is arithmetic rather than
vibes.
"""
import json
import os
import sys
import zipfile
from collections import Counter

# Lottie transform channels. Everything here is expressible as a MotionTrack.
AFFINE_CHANNELS = {"s", "r", "o", "p", "a", "sk", "sa"}

READABLE = {
    "sh": "path morph", "c": "colour", "tm": "trim path (draw-on)",
    "w": "stroke width", "d": "dash", "e": "gradient end", "g": "gradient stops",
    "h": "highlight", "ho": "highlight angle", "ir": "inner radius",
    "or": "outer radius", "is": "inner roundness", "os": "outer roundness",
    "pt": "star points", "rz": "rounded corners", "cp": "repeater copies",
}


def load(path):
    """dotLottie is a ZIP; a bare .json is the animation itself."""
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            names = [n for n in archive.namelist() if n.endswith(".json")
                     and "manifest" not in n]
            if not names:
                return None
            return json.loads(archive.read(names[0]))
    with open(path) as handle:
        return json.load(handle)


def is_animated(node):
    """Is this dict an ANIMATED Lottie property?

    ⚠️ Not `node.get("a") == 1`. That is the modern Bodymovin schema, and the
    older one — which lottie-ios's own sample corpus is full of — omits the `a`
    key entirely: `{"k": 0}` for static, `{"k": [{"t": 0, "s": [...]}, ...]}`
    for animated. Testing the flag alone found ZERO animated properties in
    13 of 19 of those files and then reported them as decomposable, because
    "no raster properties" is trivially true of a file you failed to read.

    So the test is STRUCTURAL: a property is animated when its `k` is a list of
    keyframe objects. That holds in both schemas.
    """
    if not isinstance(node, dict) or "k" not in node:
        return False
    if node.get("a") == 1:
        return True
    k = node["k"]
    return isinstance(k, list) and bool(k) and isinstance(k[0], dict)


def scan(node, in_transform, out):
    """Collect animated properties, tagged by whether they sit in a transform.

    `in_transform` is inherited: a property under a layer's `ks` or a shape
    group's `tr` is affine wherever it appears beneath it.
    """
    if isinstance(node, dict):
        if is_animated(node):
            out.append((in_transform, node.get("__key__", "?")))
            return
        transform_here = in_transform or node.get("ty") == "tr"
        for key, value in node.items():
            if isinstance(value, dict):
                value = dict(value)
                value["__key__"] = key
            scan(value, transform_here or key == "ks", out)
    elif isinstance(node, list):
        for value in node:
            scan(value, in_transform, out)


def animated_layers(doc):
    """Layers carrying animation — the unit decomposition pays for."""
    count = 0
    for layer in doc.get("layers", []):
        found = []
        scan(layer, False, found)
        if found:
            count += 1
    return count


def report(path, frame_cap):
    doc = load(path)
    if doc is None:
        return None, f"{os.path.basename(path):<20} unreadable"

    found = []
    scan(doc, False, found)
    affine = sum(1 for is_transform, _ in found if is_transform)
    raster = Counter(READABLE.get(key, key) for is_transform, key in found
                     if not is_transform)
    layers = animated_layers(doc)
    name = os.path.basename(path)

    if not raster and affine == 0:
        # ⚠️ NOT a pass. Nothing animates, which means either a static file or
        # one this script could not read — and both used to come back as
        # "DECOMPOSABLE" because the check was "no raster properties found",
        # which is trivially true of a file you failed to parse. A verdict has
        # to be earned by evidence, not by the absence of it.
        return None, (f"{name:<20}{layers:>4} anim layers{affine:>6} affine"
                      f"{0:>6} raster   NO ANIMATION FOUND — static, or unreadable")

    if not raster:
        # Affine, but is it CHEAPER? One still per animated layer against
        # `frame_cap` cells for the whole icon.
        if layers <= frame_cap:
            verdict = f"DECOMPOSABLE — {layers} stills vs {frame_cap} frames"
            ok = True
        else:
            verdict = (f"affine but NOT cheaper — {layers} animated layers "
                       f"exceeds the {frame_cap}-frame cap; bake a sheet")
            ok = False
    else:
        top = ", ".join(f"{n}x {k}" for k, n in raster.most_common(3))
        verdict = f"sheet required — {sum(raster.values())} raster props ({top})"
        ok = False

    return ok, (f"{name:<20}{layers:>4} anim layers{affine:>6} affine"
                f"{sum(raster.values()):>6} raster   {verdict}")


def main():
    paths = sys.argv[1:]
    cap = int(os.environ.get("FRAME_CAP", "24"))
    if not paths:
        print(__doc__)
        return 2
    decomposable = 0
    total = 0
    for path in sorted(paths):
        ok, line = report(path, cap)
        print(line)
        if ok is not None:
            total += 1
            decomposable += 1 if ok else 0
    print(f"\n{decomposable}/{total} decomposable at a {cap}-frame cap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
