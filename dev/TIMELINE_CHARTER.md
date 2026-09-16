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

## Which CLOCK the track is drawn on — three arrangements, one answer

⚠️ **THE AXIS IS PLAYED TIME AND THE TRACK IS THE COMPOSITION: the kept pieces,
laid end to end, in the order they will play.** Three arrangements were built and
measured to get here, and the two that failed are worth as much as the one that
did.

| Arrangement | Stretch | Constant playhead | Head-trim gesture | Verdict |
|---|---|---|---|---|
| The file at ONE scale (C1) | ✗ a rate cannot widen a piece | ✓ | ✓ | died when rates arrived |
| The file at PER-PIECE scales, cut parts greyed | ✓ | ✗ **a hole is a stretch the playhead must leap** | ✓ free, nothing moves | rejected |
| **The composition** | ✓ | ✓ nothing between the pieces to leap | ✗ paid for by scrolling | **this one** |

The requests that settle it, in the author's words: *"quand tu change la vitesse
d'un segment, il faut le stretch dans la timeline"* and *"le curseur ne devrait
jamais faire de saut et toujours se deplacer a la meme vitesse"*. The second one
is what kills the greyed-film arrangement: no amount of drawing hides a gap the
playhead has to cross.

⚠️ **WHAT THE COMPOSITION COSTS, AND HOW IT IS PAID.** A piece begins where the
pieces before it end, so dragging its START shortens it from the INSIDE: the cap
would stand still while the other end moved — reported from the device as *"quand
on grab la fenetre de selection depuis le bord gauche, ca deplace le bord droit
de la selection au lieu du bord gauche"*. The track shifts under the finger by
what the piece gave up, and for the FIRST piece that needs room a scroll view
does not have at rest, so **the leading inset grows for the length of the
gesture** and settles back on release.

⚠️ **AND THERE IS A SECOND ARRANGEMENT, FOR THE LENGTH OF A CARRY ONLY: THE
SHOT LIST.** Every piece the same width, the whole composition across the track
(`MediaTimelining.shots`, charter F26b). It exists because the scroll is off
while a piece is carried, so on the proportional track the destination is
usually somewhere the finger cannot reach. It is not a third candidate for the
axis: nothing is played, seeked or exported from it, the needle stands back with
the rest of the track while it is up, and it is gone the moment the finger is.

⚠️ **AND THE PREVIEW PLAYS THE COMPOSITION, AS ONE ITEM.** The player is handed
the arrangement itself — the kept pieces, in the track's order, at their rates —
built as an `AVMutableComposition` by the same code the export uses
(`VideoExporter.composition(of:cut:)`, fed by `MediaTimelining.exportSegments`).
Its clock IS the track's clock: item seconds are played seconds, a seam is an edit
inside the item rather than a seek, and the loop back to the start is the
player's.

It used to play the FILE and send the player to the next piece's start at every
piece's end. That held up while the pieces were in camera order and the jumps were
short; after a re-order every seam was a seek across the file, reported as *"le
passage/transitions entre les segments/clips qui ont été modifiés n'est pas très
naturel et crée une mini pause/glitch"*. The seek could not be made invisible —
it has to land, and decode, while the picture is supposed to be moving.

⚠️ **ONE EXCEPTION, AND IT IS THE HANDLES.** A handle that opens a piece stands on
film the arrangement does not contain, so while an edge is held the canvas shows
the FILE as shot (swapped in synchronously, once per gesture) and the drag seeks
it in source seconds. The release loads the new arrangement; until it lands the
clip stays stopped, and nothing reads the player's clock as the track's.

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
| **F7** | The selection is two solid end-caps with rounded outer corners (6pt — half a 12pt cap, the most Core Animation draws cleanly on a cap rounded on one side; it does not clamp), joined by thin top and bottom edges, each cap carrying a vertical pill grip. **Its inner corners are rounded too, at the held piece's own corner** — asked for as *"que le cadre intérieur des pinces ait aussi des bordures intérieures arrondies, ce qui matcherait avec les coins arrondis des segments"*. (CapCut white, Instagram yellow, TikTok red — the geometry is common to all three; IMG.LY's editor is the one reference that rounds the inside, 6 out / 8 in.) It frames ONE PIECE — the one being held. |
| **F7b** | **Nothing is selected until the author taps a piece**, and a tap past the film puts it down again. A track that arrives already bracketed claims a decision nobody has made, and with more than one piece it claims it about the wrong one. A tap on a held piece's CAP keeps it: the caps are drawn outside the piece, so treating that as "outside" would make the selection flicker off whenever a finger reaching for a handle missed by a point. |
| **F8** | **Every piece owns its two edges, and both can be dragged.** A drag is worth the film the stretch puts under it — one point of finger on a 2× piece is two frames, not one. **The only limits are the FILE's own bounds and the one-second floor. The neighbour is NOT one.** A cut does not divide the film between the two halves: each is a clip carrying its own in and out points into the whole source, and everything beyond them is still there — every editor calls it the clip's *handles* (Adobe: a split makes "a new, separate instance of the original, with updated In and Out points"; Apple calls the seam a *through edit*, where "the media content on either side of the edit point is continuous"). So pulling an edge OUT reveals the film the cut took away and PUSHES the pieces after it along; pushing it back brings them with it, glued to the cap. Pulling an edge IN leaves a GAP in the file that the result skips, which is how the middle is cut out of a clip. |
| **F8b** | A cut may not leave less than one second behind. A clip already shorter than that says so instead of offering handles that cannot move. |
| **F8c** | **A handle belongs to the clip on its side, and a gesture edits the clip it is aimed at — nothing else.** Stated by the author: *"quand on manie les pinces cela doit crop ou continuer (en fonction du geste) le clip/section du côté de la pince"*. Four consequences, each of which was a defect: a cut hands back the left half HELD, because handles exist only around the held piece and a track with nothing held has no handles at all; a tap that lands on another section's FILM takes that section, even inside the held piece's cap band (a cap is drawn twelve points outside its own piece, which at a seam is the neighbour's first frames); a press on a cap carries the piece the cap belongs to, not the piece whose film it stands on; and the spoken adjustment moves the held piece, not the last one. |
| **F8e** | **When the finger comes up, the PREVIEW comes back to the needle — the track does not go to the preview.** While a handle is held the canvas shows the frame the edge is standing on, which is how a trim is aimed. Left there, the player sits on that frame and the next beat of playback has the track FOLLOW it: the whole film slides under the needle the instant the finger lifts, which reads as every section moving at once. Measured on the device by pixel correlation: the film moved −241px on release for an 80pt trim. |
| **F8d** | **THE LEFT PINCE IS THE MIRROR OF THE RIGHT ONE.** Asked for in those words: *"si on tire la pince gauche vers la gauche… dévoiler la partie avant et pousser la section précédente — en gros ce qu'on a fait pour la pince de droite"*. The right pince holds everything BEFORE it still and pushes what follows; the left one holds the section's own film, its closing pince and every section AFTER it still, and pushes what precedes. In the composition's own coordinates a head that opens moves itself and everything after it, so the TRACK scrolls by exactly what the piece gained to cancel that — and the leading inset grows for the length of the gesture, which is what lets the FIRST piece do it at all. At the start of the film the drag is refused and the track does not scroll to pretend otherwise. Measured on the device by pixel correlation: opening pince −240px, the section before it −240px, the section being opened **0px**. |
| **F9** | The ruler scrolls with the film, labels a round number of seconds, and marks the midpoint between two labels with a dot. (CapCut and 快影 label every 2s with a 1s dot; Instagram every 4s with a 2s dot.) |
| **F10** | A fixed readout shows where the playhead is and how long the result will run — the pair CapCut and 快影 put at the left of their control row as `MM:SS / MM:SS`. |
| **F11** | A handle's hit area is a finger wide (44pt), which is much wider than it is drawn. |
| **F12** | Dragging a handle previews the frame that handle stands on. |
| **F13** | A touch on the film scrolls it; only a touch within reach of a handle drags that handle. |
| **F14** | The strip never shows empty boxes: until a tile's own frame arrives it shows the nearest frame already decoded. |
| **F19** | **The preview plays the cut and nothing else, SEAMS INCLUDED — and a seam is not a seek.** The player is handed the arrangement as one item, so there is no footage past the end to run into, no removed middle to cross, and no jump at a boundary: a re-ordered seam plays as a cut, not as a stall while the file is sought. A preview that shows removed footage shows the author something the post will not contain; one that pauses at every seam makes an edit look broken that is not. An edit that plays the same film (a split) keeps the item; any other edit — an edge, an order, a rate — is a new item, landing under the needle. |
| **F20** | The selection is ONE closed frame: the caps own the outer corners, the rails own the span between them and tuck under the caps, and no rail reaches past a cap's outer edge. **The frame's inner edge is the held film's own rounded end**: four plain white plates stand BEHIND the film at its corners, tucked under the caps and the rails, so they show exactly where the film is rounded away — the inner curve is the film's curve by construction, at any clamped radius. The plates wait for film that is not transparent (a poster or a frame), and the caps' shadow has its own path so it falls outwards only. The track's own height counts the frame — a tenant that under-declares it loses whatever hangs below, seen on the device as a selection with three sides. |
| **F21** | The screen is always dark, whatever the phone is set to. A media editor is a viewing surface before it is a form, and the letterbox, the dissolve and the band behind the film all have to be the colour that disappears next to a picture. Forced as a TRAIT, never as literal colours, so every semantic ink on the screen follows. |
| **F22** | **The clip can be cut at the needle, and each piece given its own rate.** **A cut is daylight between two rounded pieces, not a mark**: two points carved out of the FILM, centred on the cut (one at each carved end, a whole pixel at 1x, 2x and 3x), every piece rounded at its own ends — asked for as *"plutôt séparer les segments avec un léger espace et arrondir les bords"* in place of the white bar a cut used to draw. The held piece is never carved: its caps stand on its cut and the half-daylight its neighbours give up lies under them, so right after a split the cut is invisible under the needle and the cap, and plain the moment the piece is put down. A tap in the daylight takes the piece on that side of the cut. A piece that is not as shot is stamped with its rate, and the stamp is CLAMPED INTO THE VIEWPORT rather than pinned to the piece's start: at the resting scale any clip past six seconds is longer than the track, so a pinned stamp is off screen exactly when it matters. The readout counts in PLAYED seconds on both sides of the slash. And the preview plays at the rate, not only the export — the rate is built into the preview's item, so a new rate is a new item, landing on the frame the needle was on. Otherwise the only evidence of a tap is a total getting shorter. |
| **F24b** | **THE FILM IS A FIXED SHEET AND A HANDLE IS A WINDOW ON IT.** Stated by the author after two wrong arrangements: *"les frames ne bougent/se déplacent jamais, elles sont ancrées dans un container/section et c'est cette section qui bouge… quand on joue avec les pinces on révèle la suite de la piste, comme si le clip était en entier, seule la partie visible se trouve entre les pinces."* So the squares of film are cut on the **SOURCE** — square *n* always covers source seconds *n·f … (n+1)·f* — and a piece draws the ones its in/out points let through, cropping the two at its edges rather than squeezing them. Opening a piece's end reveals the next squares and moves none of the others; closing it hides them; rippling a piece along carries its squares with it, rigidly. The pictures are keyed by the second of film they show, so a piece shown twice over costs one decode and a handle drag costs none. **The two arrangements that failed**: (a) one row of squares across the whole TRACK, each showing whatever film stood at its place — cropping re-labelled every square after the cut and only the containers moved (*"c'est le container de la section qui se déplace"*); (b) squares anchored to a piece's IN POINT — they kept their places and slid their film as the piece was trimmed (*"cet effet des frames qui se déplient"*). |
| **F25** | **Nothing is PLAYED between the pieces.** Trimming ripples: the piece shortens and everything after it slides along, so the result's clock runs without a break and the playhead never leaps. The daylight between two pieces (F22) is DRAWN — carved from their film by `MediaTimelining.spans` — and never inserted into `placements`: the needle crosses two points of empty track, its own width, and loses no time. What is thrown away leaves the track; the way back to it is to drag the edge out again. The ruler marks the result and stops at its end. |
| **F26** | **A long press lifts a piece and a drag carries it to another place in the order.** The press only counts if the finger has NOT already travelled — movement before it is a scroll and stays one. The scroll is off for the length of the carry, by Apple's own recipe (disable the scroller's pan and re-enable it in the same turn, so the finger now carrying something is dropped by the scroller even if the film had begun to move). The order on the track IS the order the post plays in: it travels through `onChange` to the exporter, which inserts the pieces in the order it is given. |
| **F26b** | **While a piece is carried the track becomes a SHOT LIST: one chip per piece, all the same width, the whole composition within reach** (on screen, or — past a dozen pieces — a scroll away, see F26c). Two reasons, both reported. A carry that showed nothing read as a carry that had not happened — so the track stands back, the chip in hand is lifted, scaled and railed, and the rest are dimmed, with one selection tick at the lift and one per crossing. And with the track drawn at the length each piece RUNS for, the place a carried piece has to reach is usually off screen on a track that cannot scroll — so duration stops deciding width for the length of the gesture. This is the arrangement every editor keeps for exactly this: VideoPad's storyboard mode ("the width of each clip is the same, regardless of its duration"), Premiere Elements' Sceneline, iMovie's shot list, Instagram's Re-Order Mode, InShot's rearranging mode, Resolve's Cut page. **The list appears IN PLACE — a fade and a small scale from each chip's own centre — and leaves the same way, while the track fades out and back in under it.** Two things were reported about the first version: the chips travelled from their pieces and stretched into equal widths, and their pictures grew *"depuis le haut gauche vers le bas droit"* — a chip made in the same turn as its animation had never been laid out, so its picture was sized INSIDE the animation from a zero rectangle. Each chip is laid out before it is shown. **Daylight survives the lift**: ten points between chips, and the chip in hand grows in width only as far as leaves six on either side — at a flat 1.06 a 180pt chip gained eleven points and swallowed the gap (*"garde un léger espace entre les segments compressés"*). **While the list is up the track is PUT AWAY, not stood back** — film, frame, seams, stamps, needle, play button and readout all go, and every chip is opaque, the ones not in hand darkened by a shade rather than by transparency: a semi-transparent scrim was reported as *"on aperçoit la timeline par derrière (il y a un fouillis car tout est en semi transparent)"*. **And the ruler counts the LIST**: its marks are the list's seams, each labelled with where its piece begins in the result, drawn over that seam, without half-way dots and without the end fades (which would hide the first and last seams); crowded marks are dropped, never the two ends. It is read again at every crossing, so carrying a two-second piece past a six-second one moves the middle mark from 0:02 to 0:06 — asked for as *"attention lorsqu'on réorganise, il faut bien mettre à jour cette barre de temps"*. **And the drop leaves the needle where it is**: a carry renumbers the pieces, and the screen knows which one is playing by its number, so the drop sends the moment under the needle IN THE NEW ORDER back through `onScrub` — without it the follow scrolled the track to whichever piece had inherited the old number (measured: 0:02 → 0:00 on release). |
| **F26c** | **A chip has a floor, and a list that cannot fit SCROLLS — by itself when the chip in hand is held at an end.** Shared out evenly, a dozen pieces left chips thirty points wide: a sliver nobody can tell from its neighbour and a target no finger can aim at. So every slot is at least one square of film plus its daylight (64pt), and past that the list runs wider than the track in a `ChipScrollView` of its own — asked for as *"une largeur minimale pour les segments compressés … une scrollview horizontale"*. A list that fits is laid out exactly as before and does not scroll. **The lifted chip opens under the finger that lifted it**, as far as the list's ends allow; a list opened at its start could put it a screen away. **A chip held within 56pt of either end slides the list that way** (*"le bouger vers les extrémités des bords de l'écran fait slider la scrollview"*), driven by a display link because a thumb pressed against the bezel sends no movement; the speed is squared in the depth — a crawl at the edge of the zone, 600pt/s against the bezel — and stops at the list's end. The list moving under a still finger re-asks which slot the finger is over, so the piece travels with it, and the ruler of seams moves with the list. A second finger may scroll the list too, with the same effect. The drop stops it. |

⚠️ **DIMMING THE DISCARDED FILM IS A DELIBERATE DIVERGENCE, AND IT EARNED A
THIRD REASON.** The references do **not** do it — Instagram at high zoom leaves
the unselected part of the strip at full brightness, and no evidence of a scrim
was found in CapCut. It was kept anyway because a single clip with two handles
has no other way to say which part is being thrown away. With pieces that can be
trimmed apart there is now a case the references do not have at all: film in the
MIDDLE of the track that the result skips. Unmarked, it reads as part of the
clip.

---

## T — Technical

| # | Clause | Measured limit |
|---|---|---|
| **T1** | The follow runs at the display's refresh rate, not a fixed fraction of it, **once the band has opened**. | steady state: ≥ 55 beats/s, worst gap ≤ 34ms, film step ≤ 2.1pt at 60pt/s |
| **T1b** | ⚠️ **NOT YET MET, AND MEASURED RATHER THAN HIDDEN.** The FIRST second after the band opens still drops beats while the opening screenful of film decodes. (T10 changed what that second LOOKS like — the poster fills the strip at once — and not what it costs: the decodes still happen.) | measured 52 beats/s, 120ms, 7.2pt — improved from 43/151ms/9.1pt by the lazy strip, and the remaining cost is the first batch of exact-time decodes. The reference fix is `VideoTimelineView`'s tolerance tiering: a coarse keyframe-cheap pass (~1.5 ms a frame) to fill the strip at once, refined to exact frames behind it. |
| **T2** | No thumbnail is generated for a stretch of film that is neither visible nor about to be. | a 4-minute clip decodes no more frames at rest than a 10-second one |
| **T3** | The number of decoded thumbnails alive at once is bounded, whatever the clip's length. | ≤ 48 tiles |
| **T4** | Thumbnail requests are batched. | `images(for:)`, never a loop of `image(at:)` — measured 10.5 ms/frame against 30.5 |
| **T5** | The generator's tolerance is derived from the strip's seconds-per-thumbnail, not hard-coded. | tolerance < half the sampling interval, or the strip repeats itself |
| **T6** | No single layer's backing store exceeds the Metal limit. **No layer that can grow with the clip is rounded, clipping with sublayers, masked, shadowed, rasterised or given contents.** Each piece's film is rounded by a WINDOW that is only the hull of its squares laid out in the band (at most the track plus 432 + 108pt — 930pt on a 390pt track); squares carry no radius; the inner-corner plates are ~15pt; a cap's shadow path is 8×57. `content`, `film`, the rails and the ruler stay wide and undecorated. | 16384px = 5461pt at @3x = 91 seconds of film at 60pt/s. Enforced by `noLayerPastTheMetalLimitIsRoundedMaskedClippedOrShadowed`, which walks the whole layer tree of a held four-minute piece. |
| **T7** | A seek asked for while scrubbing is as tolerant as the scrub is fast, **within a quarter second**. | tolerance = the distance moved, capped at 0.25s — looser than that lands on keyframes, which on a 2s GOP moves the picture in two-second steps and reads as jumping |
| **T9** | **One seek in flight at a time, always chasing the latest position.** A new `seek` CANCELS the one still running, and a finger produces a sample per vsync. | measured: a burst of 24 scrub positions cancelled **23 of them** without the chase, and **0** with it |
| **T8** | The follow path allocates nothing and scans no strings per beat. | the two answers that depend on where the needle is — whether a split would act, and the rate under it — are re-asked only when the needle has moved 0.1s, which is six frames and finer than either can change |
| **T10** | The film shows something in the same turn the mode opens. | the clip's poster, which the screen is already holding for the canvas, fills every visible tile at once; a skeleton stands in the FILM's rectangle only while there is no picture of any kind |
| **T11** | **The player's clock is the track's clock, and nothing reads it when it is not.** Item seconds are played seconds of the arrangement the screen last heard land. While a load is on its way, while a handle has the file on screen, or when the track shows an arrangement the item does not play, the follower and the scrub leave the player alone. Only the newest load may land. | `MediaEditorViewController.PreviewSubject`; a follow tick while an edge is held moves nothing; two rates chosen in one turn reach the player as ONE item |
| **T12** | **A seam costs the player nothing.** No `seek`, no `timeJumpedNotification`, no new item between two pieces. | `ArrangementPlaybackTests`: 0 time jumps across a boundary inside an arrangement against ≥ 2 for the same boundaries played as seeks on the file. **Measured on the simulator (2026-09-16)**: a 10s clip cut in seven and re-ordered (the last piece moved first, so one seam jumps the source from 10s back to 0s), recorded over two loops — the longest gap between two video frames within 150ms of any seam was **35–43ms** at 30fps, i.e. the source's own cadence; the loop back to the start costs **one frame (65–70ms)**, and over a full loop the picture fell 35ms behind the wall clock, which is that frame. Method: `recordVideo`, canvas cropped and diffed frame to frame, seams located from the played lengths. |

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
| **F18** | ~~With the mode on, the bottom-left "Add a song" is replaced by a second selector carrying split and speed.~~ | **DONE.** An `IconActionBar` — the selector's capsule, metrics and tint, but MOMENTARY: `IconSelectorBar.select(_:notify:)` announces only on a change, so a second tap on the scissors would be silent and a clip could be cut exactly once. The rates stand in a row above the film, inside the band's tenant, so they grow the band rather than covering the picture. `EditorSelectorLayout`'s 70/50 rule is applied here and nowhere else. |
| **F23** | ~~An interior seam can be dragged.~~ | **DONE, AND NOT AS THE RIPPLE THIS LINE DESCRIBED.** It said moving a seam must shorten one piece and lengthen its neighbour; that is the model for a sequence of different clips, and it is wrong for one source cut into pieces. Each piece owns its own two edges: pulling one in leaves a hole that the result — and now the preview, see F19 — skips. See F8. |
| **F24** | A piece can be removed. | The plan's C2 named "split and delete"; what shipped is split and speed, which is the pair that makes a rate per piece possible. Deleting needs a rule for which piece and for what the needle does when the ground under it goes. Not implemented. |

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
