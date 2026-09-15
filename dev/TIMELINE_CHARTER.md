# The timeline charter

What the editor's timeline must do, and what it must cost. Every clause is
numbered so a test can cite it, and every clause is written so that it can
FAIL — "feels smooth" is not a clause.

Sources are the four apps the brief names (TikTok, Instagram Reels, RedNote,
Kuaishou/快影) plus CapCut, read through pixel-measured screenshots and through
the one open-source implementation of the same model,
`Tomohiro-Yamashita/VideoTimelineView`. ⚠️ **That repository has NO LICENSE
FILE** — the README says MIT, the GitHub API reports `license: null` — so it is
read for ideas and nothing is copied from it. `AndreasVerhoeven/VideoTrimmerControl`
(MIT) is the other reference and is the classic travelling-playhead model.

---

## Which model, and why this one

Two models exist and the apps do not agree.

- **Centre playhead, film scrolls.** CapCut, 快影 and Instagram's Reels editor,
  in trim mode as well as timeline mode. Measured: the playhead sits within a
  pixel or two of the screen's horizontal midpoint, and the ruler label under it
  matches the displayed current time.
- **Static strip, playhead travels.** TikTok's dedicated "Adjust clips" sheet,
  and every popular iOS trimmer library.

⚠️ **THIS TIMELINE TAKES THE FIRST, AND THE REASON IS NOT A HEAD COUNT.** The
second model cannot survive a long clip: a static strip is one screen wide
however long the film is, so a 4-minute clip gives each second a point and a half
and the handles cannot be aimed. Scrolling decouples precision from duration —
which is the whole reason the industry moved.

---

## F — Functional

| # | Clause |
|---|---|
| **F0** | The ruler, the readout and the selection are drawn in ONE fixed colour with a shadow, never in `.label` and never on a plate. They sit on the author's own footage, which is a photograph and not a background: `.label` turns black over a bright clip and vanishes into a dark one. |
| **F0b** | The ruler fades out where it would pass behind the play button or behind the readout, so neither ever competes with a timecode for the same pixels. The mask lives on a host that does NOT scroll — a mask framed in a scroll view's bounds travels with the content. |
| **F0c** | A play/pause control stands at the head of the ruler row, and a scrub does not undo a pause the author asked for. |
| **F1** | The playhead is a fixed vertical line at the exact horizontal centre of the track. The film moves; the line does not. |
| **F2** | The content carries half a track of lead-in and lead-out, so the first frame and the last can both reach the playhead. The resting offset is therefore negative. |
| **F3** | Scrolling the film seeks the clip: the picture under the playhead is the picture on the canvas. |
| **F4** | While a finger is on the track — dragging a handle, dragging the film, or the flick still decelerating — playback is stopped. It resumes when the gesture is over. |
| **F5** | Playback resumes **from the scrubbed position**, never from where the gesture began. |
| **F6** | After a scrub, the track keeps the time until the player arrives; it gives up waiting after half a second rather than freezing. |
| **F7** | The selection is two solid end-caps with rounded outer corners, joined by thin top and bottom edges, each cap carrying a vertical pill grip. (CapCut white, Instagram yellow, TikTok red — the geometry is common to all three.) |
| **F8** | A cut may not leave less than one second behind. A clip already shorter than that says so instead of offering handles that cannot move. |
| **F9** | The ruler scrolls with the film, labels a round number of seconds, and marks the midpoint between two labels with a dot. (CapCut and 快影 label every 2s with a 1s dot; Instagram every 4s with a 2s dot.) |
| **F10** | A fixed readout shows where the playhead is and how long the result will run — the pair CapCut and 快影 put at the left of their control row as `MM:SS / MM:SS`. |
| **F11** | A handle's hit area is a finger wide (44pt), which is much wider than it is drawn. |
| **F12** | Dragging a handle previews the frame that handle stands on. |
| **F13** | A touch on the film scrolls it; only a touch within reach of a handle drags that handle. |
| **F14** | The strip never shows empty boxes: until a tile's own frame arrives it shows the nearest frame already decoded. |
| **F19** | **Playback stays inside the cut.** Reaching the end handle turns back to the start handle; starting before the start handle jumps forward to it. A preview that plays on past the cut shows the author footage they have just decided to throw away, as though it were part of the post. |
| **F20** | The selection is ONE closed frame: the caps own the corners, the rails own the span between them and tuck under the caps, and no rail reaches past a cap's outer edge. The track's own height counts the frame — a tenant that under-declares it loses whatever hangs below, seen on the device as a selection with three sides. |
| **F21** | The screen is always dark, whatever the phone is set to. A media editor is a viewing surface before it is a form, and the letterbox, the dissolve and the band behind the film all have to be the colour that disappears next to a picture. Forced as a TRAIT, never as literal colours, so every semantic ink on the screen follows. |

⚠️ **NOT IN THIS CHARTER, DELIBERATELY: dimming the film outside the selection.**
It was checked and the references do **not** do it — Instagram at high zoom
leaves the unselected part of the strip at full brightness, and no evidence of a
scrim was found in CapCut. This timeline dims lightly anyway, because a single
clip with two handles has no other way to say which part is being thrown away,
and that is a deliberate divergence rather than an oversight.

---

## T — Technical

| # | Clause | Measured limit |
|---|---|---|
| **T1** | The follow runs at the display's refresh rate, not a fixed fraction of it, **once the band has opened**. | steady state: ≥ 55 beats/s, worst gap ≤ 34ms, film step ≤ 2.1pt at 60pt/s |
| **T1b** | ⚠️ **NOT YET MET, AND MEASURED RATHER THAN HIDDEN.** The FIRST second after the band opens still drops beats while the opening screenful of film decodes. | measured 52 beats/s, 120ms, 7.2pt — improved from 43/151ms/9.1pt by the lazy strip, and the remaining cost is the first batch of exact-time decodes. The reference fix is `VideoTimelineView`'s tolerance tiering: a coarse keyframe-cheap pass (~1.5 ms a frame) to fill the strip at once, refined to exact frames behind it. |
| **T2** | No thumbnail is generated for a stretch of film that is neither visible nor about to be. | a 4-minute clip decodes no more frames at rest than a 10-second one |
| **T3** | The number of decoded thumbnails alive at once is bounded, whatever the clip's length. | ≤ 48 tiles |
| **T4** | Thumbnail requests are batched. | `images(for:)`, never a loop of `image(at:)` — measured 10.5 ms/frame against 30.5 |
| **T5** | The generator's tolerance is derived from the strip's seconds-per-thumbnail, not hard-coded. | tolerance < half the sampling interval, or the strip repeats itself |
| **T6** | No single layer's backing store exceeds the Metal limit. | 16384px = 5461pt at @3x = 91 seconds of film at 60pt/s |
| **T7** | A seek asked for while scrubbing is as tolerant as the scrub is fast, **within a quarter second**. | tolerance = the distance moved, capped at 0.25s — looser than that lands on keyframes, which on a 2s GOP moves the picture in two-second steps and reads as jumping |
| **T9** | **One seek in flight at a time, always chasing the latest position.** A new `seek` CANCELS the one still running, and a finger produces a sample per vsync. | measured: a burst of 24 scrub positions cancelled **23 of them** without the chase, and **0** with it |
| **T8** | The follow path allocates nothing and scans no strings per beat. | |

---

## Not yet met, and not quietly omitted

Everything above is implemented and has a test that has been shown to fail,
except **T1b**. These are the clauses the references have and this timeline does
not — written down so the gap is a decision rather than an oversight.

| # | Clause | Where it stands |
|---|---|---|
| **F15** | ~~The track can be pinch-zoomed.~~ | **DONE.** 12 to 320 points a second, anchored on the moment under the needle. The pinch lives inside the scroller for the same reason the handle pan does, and `maximumNumberOfTouches = 1` stops the film sliding away under it. Pictures are dropped once at the start of a pinch, not per sample: a tile's index means a different moment at every scale. |
| **F16** | Running a handle into a limit reports once, by touch, on the transition INTO the clamp — never continuously while it is held there. | `VideoTrimmerControl` does exactly this (`didClamp != didClampWhilePanning`). Not implemented. |
| **F17** | A handle held still for half a second zooms the track in around it, so precision appears exactly when it is asked for. | `VideoTrimmerControl`'s dwell-to-zoom, the best idea in the reference set. Depends on F15. |
| **F18** | With the mode on, the bottom-left "Add a song" is replaced by a second selector carrying split and speed. | Asked for and still owed — it is the split and speed slices, which change what the EXPORT must produce, not only what the band shows. |

---

## Where the measurements come from

- **T1** — `-timeline-probe` prints beats per second, the worst gap between two
  beats, and what that gap is worth in points of film. Before the rate cap was
  lifted: 15 beats/s, 67ms, 4.0pt. After: 60, 17ms, 1.0pt.
- **T4, T5** — measured on a 10-minute 1080p30 H.264 clip with a 2s GOP: at the
  DEFAULT tolerance (`kCMTimePositiveInfinity` both ways) 600 requests at 1s
  intervals returned **300 distinct frames**, and 40 requests over 8 seconds
  returned **five**. There is no middle ground: below half the sampling interval
  costs ~8.5 ms/frame and is fully distinct; at or above it costs ~1.5 ms and
  snaps to keyframes.
- **T3** — at a 54pt strip on a 3x screen a thumbnail is 298x167px ≈ 198 KB.
  Six hundred of them is 116 MB, which is what kills eager whole-clip generation.
- **T6** — probed: Metal hard-asserts above 16384px.
