#!/usr/bin/env python3
"""
Emits a catalogue of AFFINE Lottie icons — artwork authored to the Ask C rule.

    Tools/IconBaker/Fixtures/generate.py out/

This exists because of a measurement, not a preference. Across every real Lottie
corpus checked, the decomposition rate is a property of the ARTWORK CLASS:

    hand-drawn illustration stickers (this repo's chat strip)   1 / 12
    lottie-ios's own mixed sample corpus                        5 / 19
    a purpose-built ICON set (useAnimations, 79 files)         33 / 78

Icons decompose; illustrations do not. The map's asset class is icons, so 42% is
the honest baseline — and it goes to 100% the moment the rule is written into the
design guide, which is what this file demonstrates.

⚠️ These are generated rather than downloaded for a licensing reason worth
recording: the useAnimations set measured above declares `"license": "MIT"` in
its npm metadata while its actual LICENSE file is a restricted CC-BY variant
reading "You do not have the rights to redistribute". The package manifest and
the licence disagree, and the licence wins. Measuring against those files is
fine; committing them is not.

Every shape here is a Lottie primitive (star, polygon, ellipse, rounded rect) —
no path data, nothing traced from anyone's artwork.
"""
import json
import os
import sys

PALETTE = [
    ("#FF9F0A", "flame"), ("#FFD60A", "spark"), ("#FF375F", "pulse-heart"),
    ("#32D74B", "leaf"), ("#0A84FF", "wave"), ("#BF5AF2", "note"),
    ("#5E5CE6", "orbit"), ("#64D2FF", "air"), ("#FF6482", "bloom"),
    ("#30D158", "sprout"), ("#FF453A", "beacon"), ("#AC8E68", "cup"),
    ("#66D4CF", "lens"), ("#FFD426", "star"), ("#7D7AFF", "gem"),
    ("#F2A0FF", "petal"),
]

# (kind, params) — Lottie primitives only.
SHAPES = [
    ("sr", {"sy": 1, "pt": 5, "or": 150, "ir": 66}),    # 5-point star
    ("sr", {"sy": 2, "pt": 6, "or": 150, "ir": 0}),     # hexagon
    ("el", {"size": 250}),                              # disc
    ("rc", {"size": 230, "round": 60}),                 # squircle
]


def prop(value, animated=None):
    """A static Lottie property, or an animated one from (t, value) pairs with
    symmetric bezier easing on every segment."""
    if animated is None:
        return {"a": 0, "k": value}
    keyframes = []
    for index, (time, current) in enumerate(animated[:-1]):
        keyframes.append({
            "t": time, "s": current, "e": animated[index + 1][1],
            "o": {"x": [0.42], "y": [0]}, "i": {"x": [0.58], "y": [1]},
        })
    keyframes.append({"t": animated[-1][0], "s": animated[-1][1]})
    return {"a": 1, "k": keyframes}


def motion(kind, length):
    """The three channels, as `ks` entries. Only the moving ones are animated,
    so the client installs one or two animations per marker rather than three."""
    half = length // 2
    if kind == "spin":
        return {"r": prop(None, [(0, [0]), (length, [360])])}
    if kind == "pulse":
        return {"s": prop(None, [(0, [82, 82, 100]), (half, [110, 110, 100]),
                                 (length, [82, 82, 100])])}
    if kind == "bob":
        return {"r": prop(None, [(0, [-18]), (half, [18]), (length, [-18])])}
    return {   # flicker: the only two-channel motion
        "o": prop(None, [(0, [55]), (half, [100]), (length, [55])]),
        "s": prop(None, [(0, [92, 92, 100]), (half, [104, 104, 100]),
                         (length, [92, 92, 100])]),
    }


def shape_items(kind, params, colour):
    red, green, blue = (int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
    if kind == "sr":
        geometry = {
            "ty": "sr", "sy": params["sy"], "nm": "poly",
            "pt": prop(params["pt"]), "p": prop([0, 0]), "r": prop(0),
            "ir": prop(params["ir"]), "is": prop(0),
            "or": prop(params["or"]), "os": prop(0),
        }
    elif kind == "el":
        geometry = {"ty": "el", "nm": "disc", "p": prop([0, 0]),
                    "s": prop([params["size"], params["size"]])}
    else:
        geometry = {"ty": "rc", "nm": "card", "p": prop([0, 0]),
                    "s": prop([params["size"], params["size"]]),
                    "r": prop(params["round"])}
    return [{
        "ty": "gr", "nm": "group", "np": 3, "it": [
            geometry,
            {"ty": "fl", "nm": "fill", "c": prop([red, green, blue, 1]),
             "o": prop(100), "r": 1},
            {"ty": "tr", "nm": "transform", "p": prop([0, 0]), "a": prop([0, 0]),
             "s": prop([100, 100]), "r": prop(0), "o": prop(100),
             "sk": prop(0), "sa": prop(0)},
        ],
    }]


def build(name, colour, shape, motion_kind, length=48, rate=24, side=512):
    transform = {
        "o": prop(100), "p": prop([side / 2, side / 2, 0]), "a": prop([0, 0, 0]),
        "r": prop(0), "s": prop([100, 100, 100]),
    }
    transform.update(motion(motion_kind, length))
    return {
        "v": "5.7.4", "fr": rate, "ip": 0, "op": length, "w": side, "h": side,
        "nm": name, "ddd": 0, "assets": [],
        "layers": [{
            "ddd": 0, "ind": 1, "ty": 4, "nm": "mark", "sr": 1, "ao": 0, "bm": 0,
            "ip": 0, "op": length, "st": 0,
            "ks": transform, "shapes": shape_items(shape[0], shape[1], colour),
        }],
    }


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "out"
    os.makedirs(out, exist_ok=True)
    kinds = ["spin", "pulse", "bob", "flicker"]
    written = 0
    for index, (colour, label) in enumerate(PALETTE):
        shape = SHAPES[index % len(SHAPES)]
        kind = kinds[(index // 2) % len(kinds)]
        name = f"{index:02d}-{label}-{kind}"
        path = os.path.join(out, name + ".json")
        with open(path, "w") as handle:
            json.dump(build(name, colour, shape, kind), handle)
        written += 1
    print(f"{written} affine Lottie icons -> {out}")


if __name__ == "__main__":
    main()
