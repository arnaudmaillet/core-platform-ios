# Viewport playback: a clip plays while its screen holds half of the display

The rule (#1914, the owner, 2026-10-30 and 2026-10-31):

> **A clip plays while its screen holds at least half of the display.** It pauses below half. Where a screen fades its sound (Shots), the sound follows the share, from full on the whole display down to silent at half.

The rule belongs to the **screen**, not to the post or the player:
- The same post plays in Shots, in a grid and on a place page, under different rules of space.
- The player (`VideoPlaybackController`) cannot see what slides over its view.

## The measure: `ViewportShare` (CoreNavigation)

One `ViewportShare` per screen, built on the screen's own `view`.

| Source | What is measured | API |
|---|---|---|
| A screen pushed over it, or popped off it | The part of the display the covering screen does not take | `track(_:cover:coversAtEnd:)` |
| Its own arrival (a push) | The part of the display it already takes | `trackArrival(_:)` |
| Its own departure (a pop, a grab carrying it off) | The part of the display it still takes | `trackDeparture(_:)` |
| A drawer or a pager of its own | A fraction the host reports | `report(_:)` |

**Three guarantees, each paid for on the owner's device:**
1. **One reference: the display.** Every share is measured against the window. A screen held smaller than half the display (by a grab) holds less than half.
2. **One view.** The cover is the covering controller's own view (`ViewportShare.cover(of:_:)`), never `view(forKey:)`, which can be a wrapper.
3. **One measure.** A covered screen whose cover measures its own place does not measure again. It **follows** that cover and takes the exact complement, in the same call. The two shares always add up to 1. At exactly half, the screen on top plays (`coveredYield`).

**At a transition's end, the transition decides:** a completed push settles on covered, a cancelled one on uncovered. UIKit calls a screen's appearance again after a cancel, with `isMovingToParent` set. `screenWillAppear` ignores a cancelled coordinator, so the transition tracked from its start settles the share.

`-viewport-share` (DEBUG) logs each screen's share, and each transition's start, end and cancel.

## Adopting it on a screen

```swift
private lazy var viewportShare: ViewportShare = {
    let share = ViewportShare(host: view)
    share.onPlaysChange = { [weak self] plays in self?.grid.setPageActive(plays) }
    return share
}()

override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    _ = viewportShare.screenWillAppear(self)   // a push in, or a plain pop off it
}

override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    viewportShare.report(1)
    grid.setPageActive(true)                  // where it always started
}

override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if viewportShare.screenWillDisappear(self) == .flight {
        grid.setPageActive(false)             // a post opened from a tile: at once
    }
}
```

`screenWillAppear` and `screenWillDisappear` answer what the host still has to do:
- **`.followed`:** a transition is tracked, and `onPlaysChange` (or `onChange`, for a screen with sound to fade) will tell the host.
- **`.now`:** there is no transition to follow, for example a tab switch. The disappearance has already reported 0. The appearance leaves the start where the host always put it.
- **`.flight`:** a post opened from the screen, flying into a zoom destination. The flight carries the tapped tile's player, and the host keeps its own rule.

**Adopted by:** Shots (`SnapFeedViewController`, with the sound fade), the For You grid, the notifications drawer (as a source), the place page, the profile and its media gallery, the Popular list, Discover's gallery, the search results and the hashtag screens. On a hero page (the profile, the place page), the banner's muted loop follows the same share through `HeroPageViewController.viewportAllowsBanner`. It still plays through the start of a departure (#1399), up to half.

**Not yet:** a screen inside a sheet (the sound sheet's gallery). A sheet at a medium detent can hold less than half of the display while it is the whole of what the viewer reads, so its share needs to be measured against the sheet, not the display.

## Shared players: a paused surface holds a still (MediaPlayback)

One asset gets one player: a post's card and its page share one. So a screen paused by the rule can still be bound to a player that another screen plays, for example the profile's tile of the post Shots shows. The pool keeps three rules:
- **A pause stops the shared clock.** The viewer's pause on a page stops the card behind it, sound and all.
- **Another surface's later play stills the paused ones.** They leave the renderer, keep their last frame, and take the player back when they resume (`VideoRenderView.holdStill`). Surfaces that only joined the player are covered too.
- **The last surface playing a shared player leaving pauses it** when every surface left on it is paused.

That later play also retires the old pause anchor, so the paused surface resumes where the clip is instead of seeking back.
