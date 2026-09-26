#!/usr/bin/env python3
"""Imports a folder of downloaded clips + sounds as the mock BFF's video corpus.

    Scripts/import-mock-clips.py ~/Downloads/medias_video_with_audio [more.mp4 more.mp3 ...]

Sources are folders and/or loose files. Pairs every video with its sound (the full track a post is set to — usually
longer than the clip), re-encodes both small enough to live in the repo, grabs
a poster frame, and writes `clips.json`, the manifest `MockClipCatalog` reads.
Then bakes each clip's map-marker preview sheet with `Tools/IconBaker` (one
segment, the clip's opening: the marker's cover is that sheet's cell 0, and it
is the poster the feed shows too) into `App/Resources/MapPreviews`, merged
into `mappreviews.json` beside the sheets that are not clips.

Pairing:
- `name.mp4` + `name.mp3` pair by file name.
- Files that share no name (one downloader stamps each file separately) pair
  by DURATION: a sound is the video's audio, within a few tenths of a second.
- Anything left without a partner is reported and skipped.

⚠️ The output is committed (no Git LFS here), so the budget is the point:
HEVC at 540p capped at 25 s and ~380 kb/s, sounds AAC 64 kb/s capped at 30 s.
Measured on the first import: ~70 MB for 50 clips.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/Resources/MockClips"
SHEETS = ROOT / "App/Resources/MapPreviews"
BAKER = ROOT / "Tools/IconBaker/.build/release/IconBaker"
VIDEO_SECONDS = 25
SOUND_SECONDS = 30
DURATION_TOLERANCE = 0.4

# Titles for the sounds whose track is known from the source's own caption.
# Everything else is the author's "original sound", which is what the
# overwhelming majority of short videos use.
KNOWN_TRACKS = {
    "Kaaris_x_evangelion": ("Veridis Quo", "Daft Punk"),
    "Meguru_Kisetsu": ("Meguru Kisetsu", "Kawai Yuto"),
    "durchdenmonsun_tokiohotel": ("Durch den Monsun", "Tokio Hotel"),
    "Most_epic_synth_pt_7": ("Most Epic Synth pt. 7", None),
    "douyin_piano": ("Piano cover", None),
    "S_n_Thu_Tr_ng_M_y": ("Sơn Thủy Trường Mây (VietZ Remix)", None),
    "QU_KH_ANH_KH_NG_TH_QU_N": ("Quá Khứ Anh Không Thể Quên (Remix)", None),
    "i_didn_t_know_how_to_let_you_know": ("i didn't know how to let you know", None),
    "fl_flstudio_beat": ("Reggaeton beat", None),
    "Since_I_wasn_t_able_to_showcase": ("Unreleased ID", None),
}


def probe(path: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "format=duration:stream=codec_type,width,height", "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    data = json.loads(out)
    video = next((s for s in data["streams"] if s["codec_type"] == "video"), None)
    return {
        "duration": float(data["format"]["duration"]),
        "width": video["width"] if video else 0,
        "height": video["height"] if video else 0,
    }


def gather(sources, suffix):
    found = {}
    for source in sources:
        paths = source.glob(f"*{suffix}") if source.is_dir() else [source]
        for path in paths:
            if path.suffix == suffix:
                found[path.stem] = path
    return found


def pair(sources):
    videos = gather(sources, ".mp4")
    sounds = gather(sources, ".mp3")
    pairs, lonely_videos = [], []
    for stem, video in sorted(videos.items()):
        if stem in sounds:
            pairs.append((video, sounds.pop(stem)))
        else:
            lonely_videos.append(video)
    # By duration, closest first, each sound used once.
    durations = {s: probe(p)["duration"] for s, p in sounds.items()}
    for video in lonely_videos:
        length = probe(video)["duration"]
        best = min(durations.items(), key=lambda kv: abs(kv[1] - length), default=None)
        if best and abs(best[1] - length) <= DURATION_TOLERANCE:
            pairs.append((video, sounds.pop(best[0])))
            del durations[best[0]]
        else:
            print(f"skip (no sound): {video.name}")
    for leftover in sounds.values():
        print(f"skip (no video): {leftover.name}")
    return sorted(pairs, key=lambda p: p[0].name)


def track_for(stem: str):
    for key, track in KNOWN_TRACKS.items():
        if key in stem:
            return track
    return (None, None)


def run(args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True)


def bake_sheets(clip_ids):
    """One preview sheet per clip, merged into the app's map-preview manifest."""
    manifest_path = SHEETS / "mappreviews.json"
    kept = [e for e in json.loads(manifest_path.read_text()) if not e["id"].startswith("clip-")]
    for stale in SHEETS.glob("clip-*.heic"):
        stale.unlink()
    scratch = OUT.parent / ".sheets"
    scratch.mkdir(exist_ok=True)
    baked = []
    for clip_id in clip_ids:
        result = subprocess.run([str(BAKER), "--out", str(scratch), "--manifest", f"{clip_id}.json",
                                 "--square", "--cell", "172", "--max-frames", "24", "--segments", "1",
                                 "--id", clip_id, str(OUT / f"{clip_id}.mp4")],
                                check=True, capture_output=True, text=True)
        entries = json.loads((scratch / f"{clip_id}.json").read_text())
        # The baker decodes with AVFoundation, as the app does: a clip it
        # cannot sheet is a clip the app cannot play. Stop rather than ship it.
        if not entries:
            sys.exit(f"{clip_id}: AVFoundation could not decode it\n{result.stdout}{result.stderr}")
        for entry in entries:
            # ⚠️ ONE segment is named `<clip>`, not `<clip>-0`, and the app finds
            # a clip's opening sheet by the `<clip>-<segment>` shape
            # (`MockMediaFixtures.openingSegment`). Named here as it expects.
            if entry["id"] == clip_id:
                entry["id"] = f"{clip_id}-0"
                renamed = f"{clip_id}-0.heic"
                (scratch / entry["asset"]).replace(scratch / renamed)
                entry["asset"] = renamed
            baked.append(entry)
    for entry in baked:
        (scratch / entry["asset"]).replace(SHEETS / entry["asset"])
    for leftover in scratch.iterdir():
        leftover.unlink()
    scratch.rmdir()
    merged = sorted(kept + baked, key=lambda e: e["id"])
    manifest_path.write_text(json.dumps(merged, indent=1, sort_keys=True) + "\n")
    size = sum((SHEETS / e["asset"]).stat().st_size for e in baked)
    print(f"{len(baked)} sheets, {size / 1_000_000:.1f} MB in {SHEETS}")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sources = [Path(arg).expanduser() for arg in sys.argv[1:] if not arg.startswith("--")]
    if not BAKER.exists():
        subprocess.run(["swift", "build", "--package-path", str(ROOT / "Tools/IconBaker"),
                        "-c", "release"], check=True)
    OUT.mkdir(parents=True, exist_ok=True)
    # `--fresh` re-encodes everything; otherwise a clip whose three files are
    # already here is kept (ids follow the sorted source names, so they are
    # stable across runs over the same sources).
    fresh = "--fresh" in sys.argv
    if fresh:
        for stale in OUT.iterdir():
            stale.unlink()

    manifest = []
    for number, (video, sound) in enumerate(pair(sources), start=1):
        clip_id = f"clip-{number:02d}"
        outputs = [OUT / f"{clip_id}.mp4", OUT / f"{clip_id}-sound.m4a", OUT / f"{clip_id}.jpg"]
        encode = not all(p.exists() for p in outputs)
        # Short side 540, long side proportional (even), whatever the aspect.
        scale = "scale='if(gt(iw,ih),-2,540)':'if(gt(iw,ih),540,-2)'"
        # ⚠️ -fpsmax 30: a 120 fps source encoded as HEVC 540p is a stream
        # AVFoundation refuses to decode (-11821 / -12911), measured on one of
        # the first import's clips — and the player would have refused it too.
        if encode: run(["-i", str(video), "-t", str(VIDEO_SECONDS), "-vf", scale, "-fpsmax", "30",
             "-c:v", "libx265", "-preset", "medium", "-crf", "30",
             "-x265-params", "vbv-maxrate=380:vbv-bufsize=760:log-level=error",
             "-tag:v", "hvc1", "-pix_fmt", "yuv420p",
             "-c:a", "aac", "-b:a", "64k", "-ac", "2",
             "-movflags", "+faststart", str(OUT / f"{clip_id}.mp4")])
        if encode: run(["-i", str(sound), "-t", str(SOUND_SECONDS), "-vn",
             "-c:a", "aac", "-b:a", "64k", "-ac", "2",
             "-movflags", "+faststart", str(OUT / f"{clip_id}-sound.m4a")])
        if encode: run(["-ss", "0.5", "-i", str(OUT / f"{clip_id}.mp4"), "-frames:v", "1",
             "-vf", "scale=320:-2", "-q:v", "6", str(OUT / f"{clip_id}.jpg")])
        encoded = probe(OUT / f"{clip_id}.mp4")
        sound_length = probe(OUT / f"{clip_id}-sound.m4a")["duration"]
        title, artist = track_for(video.stem)
        manifest.append({
            "id": clip_id,
            "width": encoded["width"],
            "height": encoded["height"],
            "duration": round(encoded["duration"], 2),
            "soundDuration": round(sound_length, 2),
            "soundTitle": title,
            "soundArtist": artist,
            "source": re.sub(r"^(tiktokio\.world_|reelsvideo\.io_)", "", video.stem),
        })
        print(f"{clip_id}  {encoded['width']}x{encoded['height']}  "
              f"{encoded['duration']:.1f}s  {title or 'original sound'}")

    (OUT / "clips.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    bake_sheets([entry["id"] for entry in manifest])
    total = sum(p.stat().st_size for p in OUT.iterdir())
    print(f"{len(manifest)} clips, {total / 1_000_000:.1f} MB in {OUT}")


if __name__ == "__main__":
    main()
