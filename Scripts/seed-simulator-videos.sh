#!/bin/bash
#
# Puts real videos in a simulator's Photos library.
#
# ⚠️ A SIMULATOR SHIPS 26 ASSETS AND EVERY ONE OF THEM IS A STILL. Measured:
# `select ZKIND, count(*) from ZASSET group by ZKIND` returns `0|26` on a fresh
# device — kind 0 is an image, and there is no kind 1 row at all. So the upload
# picker's video tile, `PhotosMediaLibrary.videoFile(for:)` and everything
# downstream of it have never once run against a real `PHAsset` video on a
# simulator; `-upload-fake-library` substitutes a mock library instead, which
# answers a different question.
#
# ⚠️ AND `xcrun simctl addmedia` IS THE ONLY WAY IN. It adds assets and cannot
# create an album, which is why `DebugPhotoAlbumSeeder` exists beside it.
#
# Usage:
#   Scripts/seed-simulator-videos.sh [udid] [--force]
#
# With no udid it takes the booted device. Idempotent: it skips a library that
# already holds videos unless --force is given. Clips are cached under
# ~/.cache/core-platform-ios/sim-videos, so a second run is offline.
set -euo pipefail

CACHE="${HOME}/.cache/core-platform-ios/sim-videos"
FORCE=0
UDID=""

for argument in "$@"; do
  case "$argument" in
    --force) FORCE=1 ;;
    *) UDID="$argument" ;;
  esac
done

if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices booted -j | /usr/bin/python3 -c \
    "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for v in d.values() for x in v), ''))")
fi
if [ -z "$UDID" ]; then
  echo "no booted simulator, and no udid given" >&2
  exit 1
fi
echo "device: $UDID"

# ── Already seeded? ───────────────────────────────────────────────────────────
# ZKIND 1 is a video. Reading the library's own database is the only way to ask;
# there is no simctl query for it. A missing database is not a failure — it is a
# device whose Photos app has never opened — so fall through and add.
DB="${HOME}/Library/Developer/CoreSimulator/Devices/${UDID}/data/Media/PhotoData/Photos.sqlite"
if [ "$FORCE" -eq 0 ] && [ -f "$DB" ]; then
  HAVE=$(sqlite3 "$DB" "select count(*) from ZASSET where ZKIND = 1;" 2>/dev/null || echo 0)
  if [ "${HAVE:-0}" -gt 0 ]; then
    echo "already holds $HAVE video(s) — pass --force to add another set"
    exit 0
  fi
fi

mkdir -p "$CACHE"

# ── The public encodes ────────────────────────────────────────────────────────
# The same three `DebugMediaLibrary.realClips` uses, so the mock library and the
# device library show the same films and a difference between them is a
# difference in the CODE rather than in the fixture. `MockMediaFixtures` is the
# canonical catalogue and records the ffprobe dimensions and the dead sources.
fetch() {
  local name="$1" url="$2"
  if [ -s "${CACHE}/${name}" ]; then
    echo "  cached  ${name}"
    return
  fi
  echo "  fetching ${name}"
  curl -fsSL --retry 2 -o "${CACHE}/${name}.part" "$url"
  mv "${CACHE}/${name}.part" "${CACHE}/${name}"
}

echo "clips:"
fetch bunny-720-10s.mp4 "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4"
fetch sintel-trailer-52s.mp4 "https://media.w3.org/2010/05/sintel/trailer.mp4"
fetch bunny-360-10s.mp4 "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4"

# ── The ones the web does not offer ───────────────────────────────────────────
# ⚠️ DERIVED FROM A REAL ENCODE, NOT A TEST PATTERN. A synthetic gradient would
# make an orientation bug invisible: you cannot tell a rotated colour ramp from
# an upright one. These are cut out of the film above, so a portrait clip drawn
# sideways is obvious at a glance.
derive() {
  local name="$1"; shift
  if [ -s "${CACHE}/${name}" ]; then
    echo "  cached  ${name}"
    return
  fi
  echo "  deriving ${name}"
  ffmpeg -nostdin -loglevel error -y "$@" "${CACHE}/${name}.part.mp4"
  mv "${CACHE}/${name}.part.mp4" "${CACHE}/${name}"
}

# Portrait, which every commonly cited public bucket has stopped serving: the
# editor's crop, the poster's aspect and the track's filmstrip all read the
# preferred transform, and a landscape-only fixture never exercises it.
derive bunny-portrait-9s.mp4 -i "${CACHE}/bunny-720-10s.mp4" -t 9 \
  -vf "crop=ih*9/16:ih,scale=1080:1920" -c:v libx264 -preset veryfast -crf 24 -c:a aac

# HEVC, which is what an iPhone actually records. H.264 everywhere else would
# leave the one codec the users' own clips arrive in untested.
derive bunny-hevc-8s.mp4 -i "${CACHE}/bunny-720-10s.mp4" -t 8 \
  -c:v hevc_videotoolbox -tag:v hvc1 -b:v 2M -c:a aac

# Below the one-second floor a cut cannot leave behind, so the editor's
# "too short to trim" notice is reachable on a device rather than only in a test.
derive bunny-tiny-0s.mp4 -i "${CACHE}/bunny-720-10s.mp4" -t 0.6 \
  -c:v libx264 -preset veryfast -crf 24 -an

# Silent, because an export that assumes an audio track is a crash waiting for
# somebody's screen recording.
derive bunny-silent-6s.mp4 -i "${CACHE}/bunny-720-10s.mp4" -t 6 -an \
  -c:v libx264 -preset veryfast -crf 24

# ⚠️ THE SHAPE AN iPHONE ACTUALLY RECORDS, AND IT IS NOT THE PORTRAIT ONE ABOVE.
# A phone held upright writes LANDSCAPE frames — 1280x720 here — and a 90-degree
# rotation in the track's metadata; nothing is rotated in the pixels. So every
# reader has to honour `preferredTransform`, and a reader that forgets it draws
# the clip on its side while a file whose pixels are already portrait looks fine.
# Verified with `ffprobe -show_entries stream_side_data=rotation`: width=1280,
# height=720, rotation=90.
derive bunny-rotated-7s.mp4 -display_rotation 90 -i "${CACHE}/bunny-720-10s.mp4" -t 7 -c copy

# ── In they go ────────────────────────────────────────────────────────────────
echo "adding:"
for clip in "${CACHE}"/*.mp4; do
  xcrun simctl addmedia "$UDID" "$clip"
  echo "  $(basename "$clip")  $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$clip" | cut -c1-5)s  $(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,codec_name -of csv=p=0 "$clip")"
done

if [ -f "$DB" ]; then
  echo "library now holds $(sqlite3 "$DB" "select count(*) from ZASSET where ZKIND = 1;" 2>/dev/null || echo '?') video(s)"
fi

cat <<'LEGEND'

Which tile is which — the grid stamps the duration, and that is the only label:

  0:52  sintel      long enough to scroll the track and coarsen its ruler
  0:10  bunny 720   the ordinary case
  0:10  bunny 360   the same, smaller — the two are interchangeable
  0:09  portrait    1080x1920 pixels, no rotation metadata
  0:08  hevc        what an iPhone encodes with
  0:07  rotated     1280x720 pixels + a 90-degree preferredTransform
  0:06  silent      no audio track
  0:01  tiny        0.6s, under the one-second floor a cut may leave behind

⚠️ THE FIRST LAUNCH STILL ASKS FOR THE PHOTO LIBRARY, and neither
`simctl privacy grant photos` nor `grant all` skips it on iOS 26 — measured, both
times the prompt came up anyway. Tap "Allow Full Access" once; the grant sticks
until the device is erased.

⚠️ RELAUNCH THE APP AFTER THIS. `PhotosMediaLibrary` takes one snapshot and
registers no `PHPhotoLibraryChangeObserver`, so a library that grows while the
picker is open does not grow on screen — measured: the album pills read the new
counts and the grid stayed empty.
LEGEND
