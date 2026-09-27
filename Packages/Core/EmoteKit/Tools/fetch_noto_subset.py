#!/usr/bin/env python3
"""Fetch the bundled subset of Google's Noto Emoji Animation.

Noto Emoji Animation (https://googlefonts.github.io/noto-emoji-animation/) is
licensed CC BY 4.0 — see `Sources/EmoteKit/Resources/ACKNOWLEDGEMENTS.md`.

The app bundles a CURATED SUBSET, never the whole set, and fetches nothing at
runtime: this script is the only thing that talks to the network, and it runs
on a developer's machine. Re-run it after editing `WANTED`:

    python3 Packages/Core/EmoteKit/Tools/fetch_noto_subset.py

It writes, under `Sources/EmoteKit/Resources/Noto/`:
  - `<codepoint>.json.xz` — the Lottie, minified, its floats rounded to three
    decimals (the animations are drawn at most 128 px, where a thousandth of a
    1024-unit canvas is an eighth of a pixel), then XZ-compressed. Raw, the
    subset is ~15 MB of JSON; compressed it is ~1.6 MB, and Foundation's
    `.lzma` decompression reads the XZ container natively
    (`NotoLottieSource`);
  - `manifest.json` — glyph, codepoint, name, keywords and section for each
    entry, in `WANTED` order (which is roughly Unicode's frequency ranking, so
    a picker can list "popular first" without any other data).
"""

import json
import lzma
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Sources", "EmoteKit", "Resources", "Noto")
API = "https://googlefonts.github.io/noto-emoji-animation/data/api.json"
LOTTIE = "https://fonts.gstatic.com/s/e/notoemoji/latest/{}/lottie.json"

# Roughly Unicode's emoji frequency ranking (2021), then a few the app's own
# subjects want (places, food, music, travel). Entries Noto does not animate
# are skipped; duplicates keep their first position.
WANTED = """
😂 ❤️ 🤣 👍 😭 🙏 😘 🥰 😍 😊 🎉 😁 💕 🥺 😅 🔥 ☺️ 🤦 ♥️ 🤷 🙄 😆 🤗 😉 🎂 🤔
👏 🙂 😳 🥳 😎 👌 💜 😔 💪 ✨ 💖 👀 😋 😏 😢 👉 💗 😩 💯 🌹 💞 🎈 💙 😃 😡 💐
😜 🙈 🤞 😄 🤤 🙌 🤪 ❣️ 😀 💋 💀 👇 💔 😌 💓 🤩 🙃 😬 😱 😴 🤭 😐 🌞 😒 😇 🌸
😈 🎶 ✌️ 🎊 🥵 😞 💚 ☀️ 🖤 💰 😚 👑 🎁 💥 🙋 ☹️ 😑 🥴 👈 💩 ✅ 👋 🤮 😤 🤢 🌟
❗ 😥 🌈 💛 😝 😫 😲 ‼️ 🔴 🌻 🤯 💃 👊 🤬 🏃 😕 ⚡ ☕ 🍀 💦 ⭐ 🦋 🤨 🌺 😹 🤘
🌷 💝 💤 🤝 🐰 😓 💘 🍻 😟 😣 🧐 😠 🤠 😻 🌙 😛 🤙 🙊 🚀 🎯 🍕 🍿 ⚽ 🏆 🎵 🌊
🐶 🐱 🦄 🍷 🍺 😮 😯 🥹 🫶 🫠 🤡 👻 🎃 🎄 🌍 📍 ✈️ 📸 🎤 🎧 🎮 💎 🍔 🍩 🥂 🍾
🤑 😵 🥶 😪 🫡 🤫 🙀 🐍 🌵 🍉 🍓 🥑 ❄️ 🎸 💡 ⏰ 🧡 🤍 🤎 💫 💨 🫣 🤐 😶 🫢 😷
🤒 🥱 😖 🥲 😦 😧 😨 😰 🙁 💢 👽 🤖 😺 😸 🐵 🦊 🐼 🐧 🐣 🐝 🐙 🐬 🐳 🌱 🍁 🍂
🌼 ☘️ 🎆 🎇 🧨 🏁 🚨 🚗 🌮 🍜 🍣 🍪 🧁 🍫 🍭 👅 🫵 👆 ☝️ 🤌 🤏 🙅 🙆 💁
""".split()

# Noto's categories, folded onto the picker's sections.
SECTIONS = {
    "Smileys and emotions": "smileys",
    "People": "people",
    "Animals and nature": "nature",
    "Food and drink": "food",
    "Activities and events": "activities",
    "Travel and places": "travel",
    "Objects": "objects",
    "Symbols": "symbols",
    "Flags": "symbols",
}


def codepoint(glyph):
    return "_".join("%x" % ord(c) for c in glyph)


def fetch(url, attempts=4):
    request = urllib.request.Request(url, headers={"User-Agent": "EmoteKit-fetch/1"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except OSError:
            if attempt == attempts - 1:
                raise
            time.sleep(1 + attempt)


def rounded(value):
    if isinstance(value, float):
        r = round(value, 3)
        return int(r) if r == int(r) else r
    if isinstance(value, list):
        return [rounded(v) for v in value]
    if isinstance(value, dict):
        return {k: rounded(v) for k, v in value.items()}
    return value


def words(tag):
    return [w for w in tag.strip(":").replace("-", " ").split() if w]


def main():
    icons = json.loads(fetch(API))["icons"]
    by_codepoint = {icon["codepoint"]: icon for icon in icons}
    os.makedirs(OUT, exist_ok=True)

    manifest, seen, missing = [], set(), []
    for glyph in WANTED:
        key = codepoint(glyph)
        candidates = [key, key.replace("_fe0f", ""), key + "_fe0f"]
        hit = next((c for c in candidates if c in by_codepoint), None)
        if hit is None:
            missing.append(glyph)
            continue
        if hit in seen:
            continue
        seen.add(hit)
        icon = by_codepoint[hit]
        path = os.path.join(OUT, hit + ".json.xz")
        if os.path.exists(path):
            # Already fetched: a re-run only downloads what an edit to WANTED
            # added.
            with open(path, "rb") as fh:
                lottie = json.loads(lzma.decompress(fh.read()))
        else:
            lottie = rounded(json.loads(fetch(LOTTIE.format(hit))))
            raw = json.dumps(lottie, separators=(",", ":")).encode("utf-8")
            with open(path, "wb") as fh:
                fh.write(lzma.compress(raw, format=lzma.FORMAT_XZ, preset=9 | lzma.PRESET_EXTREME))
        tags = icon["tags"]
        name = " ".join(words(tags[0])) if tags else hit
        keywords = sorted({w for tag in tags for w in words(tag)})
        manifest.append({
            "glyph": glyph,
            "codepoint": hit,
            "name": name,
            "keywords": keywords,
            "section": SECTIONS.get(icon["categories"][0], "symbols"),
            "seconds": round((lottie["op"] - lottie["ip"]) / lottie["fr"], 3),
        })
        print(f"{glyph} {hit} {name}", file=sys.stderr)

    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=1)
    print(f"{len(manifest)} emoji, missing from Noto: {' '.join(missing) or 'none'}", file=sys.stderr)


if __name__ == "__main__":
    main()
