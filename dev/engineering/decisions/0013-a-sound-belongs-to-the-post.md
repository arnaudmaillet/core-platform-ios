# 0013. A sound belongs to the post, never to one of its media

Date: 2026-10-28, text posts 2026-11-01 · Status: Accepted · Issues: #1849, #1999

## Context
A post is not a media: a carousel is one post whose pages are clips and photographs. The contract carries one `audio_ref` per post. The client resolved sounds per clip (`sound(forPost:clip:)`), so a carousel went silent on its photographs and changed sound from one clip to the next. Text posts borrowed a sound from the mock corpus and grew a sound slot they had no use for.

## Decision
The owner ruled:
- **One sound per post**, resolved by post id (`PostSoundProviding.sound(forPost:)`, FeedInterface). It plays across the whole carousel, photographs included.
- **A carousel's clips are always muted.** The client never derives the post's sound from one of its media; a carousel with no sound attached is silent.
- **A single-clip post with no sound attached** is heard with its clip's own sound, played from the clip for sync.
- **A text post has no sound.** One sent with an `audio_ref` is ignored, not played (`SnapSoundState.sound(for:)`).

## Consequences
- Any per-media sound resolution is the old model; don't reintroduce one.
- Screens that show a sound (the toolbar's song, the sound sheet, the sound page) ask the post, whatever page is on screen.
- Low Power Mode keeps a carousel's track like a clip's own sound, and silences a single photograph's song.
