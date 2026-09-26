#!/usr/bin/env python3
"""Imports a folder of songs as the sounds the mock corpus sets its photo,
collection and text posts to.

    Scripts/import-mock-songs.py ~/Downloads/songs

Re-encodes each (AAC 64 kb/s, at most 30 s — the same budget as the clips'
sounds) into `CoreNetworkingMocks/Resources/MockSongs`, and writes
`songs.json`, the manifest `MockSongCatalog` reads.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/Resources/MockSongs"
SECONDS = 30

# The track, where the source names one; otherwise the source's own caption,
# tidied, is the sound's title — which is how short-video sounds are named.
KNOWN = {
    "Champagne_coast": ("Champagne Coast (piano cover)", None),
    "Haru_haru": ("Haru Haru", "BIGBANG"),
    "Don_t_know_what": ("Don't know what to call this", None),
    "L_n_ti_p_led": ("Birthday edit", None),
    "So_gorgeous": ("Across Worlds", None),
    "T_L_nh_Minh": ("Drama edit", None),
    "b_c_i_t_o_h_nh": ("Scene edit", None),
    "be_honest_tho": ("Dark fantasy", None),
    "jujingyi_chinagirl": ("China girl", None),
    "jujingyi_inzanare": ("Kiku", None),
    "s_p_full_r_ae_i": ("Producer loop", None),
    "the_dragon_nation": ("The Dragon Nation", None),
}


def title_for(stem: str):
    for key, track in KNOWN.items():
        if key in stem:
            return track
    words = re.sub(r"^tiktokio\.world_", "", stem).replace("_", " ").strip()
    words = re.sub(r"\s+\d[\d ]*$", "", words)  # trailing dates/ids
    return (words[:1].upper() + words[1:], None)


def duration(path: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", str(path)],
                         check=True, capture_output=True, text=True).stdout
    return float(out)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    folder = Path(sys.argv[1]).expanduser()
    OUT.mkdir(parents=True, exist_ok=True)
    for stale in OUT.iterdir():
        stale.unlink()
    manifest = []
    for number, source in enumerate(sorted(folder.glob("*.mp3")), start=1):
        song_id = f"song-{number:02d}"
        target = OUT / f"{song_id}.m4a"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(source), "-t", str(SECONDS), "-vn",
                        "-c:a", "aac", "-b:a", "64k", "-ac", "2", "-movflags", "+faststart", str(target)],
                       check=True)
        title, artist = title_for(source.stem)
        manifest.append({"id": song_id, "title": title, "artist": artist,
                         "duration": round(duration(target), 2)})
        print(f"{song_id}  {manifest[-1]['duration']:5.1f}s  {title}")
    (OUT / "songs.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    total = sum(p.stat().st_size for p in OUT.iterdir())
    print(f"{len(manifest)} songs, {total / 1_000_000:.1f} MB in {OUT}")


if __name__ == "__main__":
    main()
