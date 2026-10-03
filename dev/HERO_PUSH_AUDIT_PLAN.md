# Hero push transition — audit & change plan

Audit of the hero/zoom navigation push (CoreNavigation `Zoom*`, its presenters
and the video pool across a flight), at `develop` 4b7481da, 2026-10-03.
Read-only so far: nothing built or run.

Second pass (requested 2026-10-03): the dismiss pipeline end to end, the
reveal/card family (text posts, card-shaped closes), and the arrival screen's
resting state in both directions, covering For You, Maps, Profile, PlaceProfile,
Search, Discover and PostList. Its findings are 1.13–1.27 and 2.7–2.15 below.
No new hang was found in the dismiss legs; every gate there is bounded.

Status tags:
- **VERIFIED**: I read the code path myself.
- **TRACED**: an audit pass traced it, but I have not re-read it.
- **SUSPECTED**: the code allows it; it still needs a simulator repro before it is fixed.

## What is already sound (keep it)

- **Module boundaries.** CoreNavigation depends on no feature, and features do
  not import each other (they go through FeedInterface and MapsInterface).
- **`completeTransition` runs exactly once on every animator branch.**
  - The animator never calls `stopAnimation`.
  - `releaseFlightState` breaks the animator ↔ property-animator cycle.
- **Every readiness gate is wall-clock and bounded:**
  - 0.15s first-frame hide;
  - 0.75s landing hold;
  - 3.0s hydration cover;
  - the spring duration for the live-media retry.
- **The touch shield is removed on every branch.**
- **Display-link helpers hold no owner cycle.** Each one is retained only by its
  link and captures weakly.
- **Re-entrancy is locked.** A double tap is safe:
  - For You: `activeTransition` plus `transitionCoordinator == nil`.
  - Maps: `MapOpenGate`.
- **The static-dispatch trap is handled.** Every defaulted member is a declared
  requirement.

## Phase 1: correctness fixes (small and surgical, one test each)

| # | Defect | Status | Fix |
|---|---|---|---|
| 1.1 | **Possible permanent HANG.** `ZoomFlightInterruptor.handleTouch` returns on `container.window == nil` in *every* state (ZoomFlightInterruptor.swift:136). A finger freezes a flight; the container leaves the window (route `selectTab`, full-screen modal); the touch-up is then ignored. Neither `finish()` nor `cancel()` runs, so `completeTransition` never runs and the stack stays mid-transition forever. Every open guard then refuses. | VERIFIED (guard); SUSPECTED (trigger) | Gate on the window only at `.began`. On touch-up, always resolve; when frozen, call `finish()`. Unit test the touch-up with the container off its window. |
| 1.2 | **`adoptSurface(_:replacing:)` stops `previous` even when adoption FAILS.** Its `defer` runs on every `return false` (VideoPlaybackController.swift:1535). A failed adopt kills a playing player. | VERIFIED | Stop `previous` only on success. Test in `PlayerPoolHygieneTests`. |
| 1.3 | **Opening from a live-previewing map pin blanks the page.** The card mirrors a *Maps-pool* player. `stopAll()` at `onDestinationShown` retires it. The landing then adopts the dead card surface into the feed cell, and 1.2 kills the feed's own new player. | TRACED; SUSPECTED on screen | 1.2, plus `SnapFeedCell.adoptLiveRenderView` refuses a view whose player its pool does not own. Repro on the sim first. |
| 1.4 | **A reversed push from `FeedFeatureBuilder` leaks.** This route serves Profile, PlaceProfile tiles, the sound sheet, the wallet and For You rows. `onPresentationCancelled` only restores the tab bar (FeedFeatureBuilder.swift:442). What stays behind: the retainer cycle (325/336), `nav.delegate` still on the dead chain, and `cardClose` alive. The next flight saves that stale delegate as its `previousDelegate`. | VERIFIED | Same idempotent close-out as `onSourceReturned`: restore the delegate (only if it is still ours), `retainer.transition = nil`, `cardClose = nil`. |
| 1.5 | **Search never ends its playback handoff.** `PostSetSurfaceViewController.swift:128` calls `beginPlaybackHandoff` and never calls `end`. The tapped tile stays frozen, is excluded from ranking and keeps its loan. **PlaceProfile** never clears `focus`. | VERIFIED (Search); TRACED (PlaceProfile) | Call `endPlaybackHandoff()` in `viewDidAppear`, as Discover and PostList do. Clear `focus` in PlaceProfile. |
| 1.6 | **A carousel landing adopts page 0's clip.** `adoptLivePlayback` and `adoptHostedPlayback` key by `posts[index].videoURL` (ForYouGridPage.swift:1798, 1843). The flight uses `currentPageVideoURL`. | VERIFIED | Use `currentPageVideoURL ?? videoURL`, as at :1687/:1727. |
| 1.7 | **The dismiss leg's first-frame hide can fire AFTER the pop has completed** (after a stall or a backgrounding). It sets the reused feed's `alpha = 0`. The guard flag is set only on cancel (ZoomAnimator.swift:1061-1073, 1127). | VERIFIED (code); SUSPECTED (timing) | Set the flag on both terminal branches (rename it `isFirstFrameHandoffClosed`). Do the same on the present leg. |
| 1.8 | **A grab driver can get stuck in "interacting".** The `startInteractiveTransition` guard completes without resetting `isInteracting`, and `releaseGrab` returns early (ZoomDismissInteractionController.swift:218, 631). `ZoomTransitionController:298` then hands that dead driver every later pop. | VERIFIED; latent | Reset `isInteracting` and re-enable scrolling on both early exits. |
| 1.9 | **The grab reads the page rect BEFORE `layoutIfNeeded`**, which is the ordering the tap-back comment calls a measured bug. Only the tap-back falls back on an empty rect. | VERIFIED | One `ZoomFlight.pageFrame(destination:container:)` helper (lay out, then fall back on empty or non-finite), used by all 3 legs. |
| 1.10 | **`ExternalHeroZoomSource.zoomHeroFrame` ignores `zoomSourceIsOnScreen`** (ExternalHeroZoomSource.swift:134). A prefetched off-screen cell becomes the landing rect. | VERIFIED | Mirror `ForYouGridZoomSource`, and use `ZoomTransitionGeometry.centeredFallback`. |
| 1.11 | **A back-button pop ignores `zoomLandingAcceptsHero`** (ZoomTransitionController.swift:271). Only the grabs ask it. | TRACED | Add it to the `.card` refusal, so the hero refuses on either condition. |
| 1.12 | **The present's `toView == nil` guard skips `onPresentationReversed`** (ZoomAnimator.swift:209), which leaves the owner's lock set. | VERIFIED; latent | Fire the callback. |
| 1.13 | **A reversed present leaves the REUSED feed at `alpha 0`.** The reversed branch never calls `setZoomContentHidden(false)` (ZoomAnimator.swift:420-446). The next open through the plain-push path then arrives black, while its controls still take taps. | VERIFIED | Reveal in the reversed branch, and reset `view.alpha` in `repoint`. |
| 1.14 | **Every post opened FROM the place page leaks its transition controller.** The page's `viewDidAppear` re-asserts its slide driver before UIKit sends `didShow`. That driver forwards `didShow` only to the delegate it captured ONCE (the map's), so the post's `onSourceReturned` never fires and the retainer cycle never breaks (InteractiveSlideDismissal.swift:333-338, 698). | VERIFIED (code) | When a re-assert displaces a different live delegate, forward the next `didShow` to it as well (the `displacedDelegate` contract). The root fix is PR D. |
| 1.15 | **A builder hero grab re-takes the delegate slot from the card-close driver** (`nav?.delegate = transition`, FeedFeatureBuilder.swift:387). After a cancelled grab, a text-page close runs UIKit's non-interactive pop, so the drag is not followed. The card-close driver also leaks on EVERY committed hero-grab close (its `onFeedPopped` captures the retainer strongly). | TRACED (2 passes) + line VERIFIED | Do not take the slot when a card close is installed (it already forwards `.hero` pops). Capture the retainer weakly. |
| 1.16 | **The chevron during a live transition** raises the dock for a pop UIKit then drops (`closeFeed`, SnapFeedViewController.swift:652). During a present, the dock stays over the feed. | VERIFIED | `guard nav.transitionCoordinator == nil` at the top. |
| 1.17 | **`isAwaitingRevealPresentation` is raised by every CLOSE staging** (`TextRevealInstaller.swift:141`) and lowered only in `viewDidAppear`. After a committed close it stays set on the reused feed, so the next open replays the comment-band entrance, defers the author pill and suppresses prewarm. | VERIFIED (raise/lower sites) | Raise it for openings only, and reset it in `repoint`. |
| 1.18 | **`showTabBarNativelyNextTurn` does not re-check the stack** (TabBarRevealPolicy.swift:116). A tile tap inside that turn re-opens the feed, and then the queued show raises the bar over it. | VERIFIED | Re-check `transitionCoordinator == nil && showsAppTabBar(for: top)` inside the async block. |
| 1.19 | **No open lock on the builder route** (Profile, Discover, Search, PlaceProfile). A double tap gives two `beginHandoff` calls and two pushes. | TRACED | Move PostList's guard (`transitionCoordinator == nil && top === presenter`) into `presentSnapFeedHero`. |
| 1.20 | **Profile Saved tab:** `viewWillAppear` reloads to skeletons during the dismiss, so the card lands on the fallback rect. The cell provider does not re-conceal the flying post, so the tile shows under the landing card. | TRACED | Do not publish `.loading` over shown content, and re-conceal in the cell provider (as ForYouGridPage:3318 does). |
| 1.21 | **The reveal grab's finish runs only through `[weak self]`** (RevealDismissInteractionController.swift:514). Once `releaseSwipe` has dropped its reference, nothing guarantees `completeTransition` runs. | SUSPECTED (possible HANG) | Capture strongly; it is already bounded by the 6s settle ceiling. |
| 1.22 | **A tap-back never asserts source concealment** (the grab does). A reversed tap-back UN-hides the source while the feed stays, so the next close flies over a visible twin marker. | TRACED | Conceal in `dismiss()` after staging. On reversal, conceal as the grab plan does (`ZoomGrabSettlement`). |
| 1.23 | **Maps:** a reversed present keeps `cardClose` alive. The `viewDidAppear` backstop does not clear a stale `activeTransition`. `syncBarsPosition` is not re-run when a flight ends. | TRACED | Nil `cardClose`; complete the backstop; re-sync after each `activeTransition = nil`. |
| 1.24 | **`MapAnnotationView` / `MapClusterAnnotationView.prepareForReuse` do not reset `isHidden`.** A marker concealed while its annotation was retired comes back invisible and untappable. | TRACED (moved here from 4.6) | Reset it in both overrides. |
| 1.25 | **`PlaceProfileViewController.setContentScrollEnabled` toggles `isPagingEnabled`, not scrolling** (:2816). The pager is not frozen during a grab. | TRACED | Use a restore-style `ScrollLock`, like the feed. |
| 1.26 | **Reversed tap-back:** the dock stays up over the returning feed, then vanishes in one frame (`setTabBarHidden(true, animated: false)`). | TRACED | `hideTabBarNatively()` (animated) in that backstop. |
| 1.27 | **For You claims `playback.focus` before `openFeed`'s guards run.** A rejected open leaves a stale focus. | TRACED | Claim it after the guards, or clear it on reject. |


## PR A outcome (2026-10-03)

Status after implementation, with verification notes:

- **Done:** 1.1–1.24 and 1.26.
- **1.7 confirmed by test.** Against the old animator, a frame-0 gate
  still pending at landing DID hide the feed after a completed close
  (`HeroPushHardeningTests.aLandedCloseIsNotHiddenByALateFrameZeroGate`). The
  four animator-branch tests all fail on the old animator and pass on the new one.
- **1.25 was half right.** `HorizontalPagerView.isPagingEnabled` does gate
  scrolling, so the pager WAS frozen during a grab. The real defect was the
  restore: it forced `true` and overwrote paging that was off for its own
  reasons. It now uses `ScrollLock`.
- **1.27 not changed.** The stale focus left by a refused open is cleared by
  `endPlaybackHandoff()` at the next return (it calls `focus(nil)`), so it
  heals itself.
- **1.14 fix shape.** `InteractiveSlideDismissal.install` remembers a delegate
  it displaces while re-asserting, and forwards it exactly the next `didShow`.
- **The builder close-out** releases its flight objects one turn later. It
  runs inside one of their own delegate callbacks (the card close forwards
  `didShow` to the flight and keeps executing), so releasing them inline would
  free an object mid-method.

## Phase 2: leftovers that outlive the transition (generation tokens)

Today nothing that outlives `completeTransition` can be cancelled. On a REUSED
destination (For You keeps one `SnapFeedViewController`), leftovers from one
flight can act on the next.

| # | Defect | Status | Fix |
|---|---|---|---|
| 2.1 | **Landing cover** (ZoomAnimator.swift:487-563). Up to 3s, non-interactive. Its gate later adopts the cover's surface into *whatever cell is active*. Not cancelled by tap-back, grab, paging or re-present. Scenarios: (a) open A cold, close, open B inside 3s, and A's cover/adopt lands on B; (b) the page is swiped under a frozen cover. | VERIFIED (code); SUSPECTED (repro) | A `ZoomLandingCover` object owned by the destination, carrying the post ID it was built for. It is dropped immediately, with no adopt, on dismiss/grab begin, `repoint`, a new present or the first drag. The adopt is skipped if the active post ≠ the captured ID. |
| 2.2 | **Landing hold** (≤0.75s, ZoomAnimator.swift:1184). The open locks are released before it ends, so a new tap flies over the old card, and tapping the same tile shows a duplicate. | TRACED | The next present on that stack drops any live hold first (a hold registry keyed by navigation controller). |
| 2.3 | **Gesture recognizers are never removed:** every For You open adds a grab pan to the *same* cached `feed.view` (ForYouViewController.swift:1506, 1680), and the interruptor's 0s long-press and pan stay on the container unless touched. N opens leave N-1 dead pans arbitrating against the pager. | VERIFIED (pans); SUSPECTED (container) | A `ZoomTransitionController.invalidate()` that detaches every recognizer it installed. Called from every close-out. Add census keys for them. |
| 2.4 | **The reused feed keeps its active page's loan/joined surface** after it is popped. `viewDidDisappear` can then pause the *tile's* player through `boundPlayer`. A reversed present runs `zoomTransitionDidEnd` on the discarded feed: bitrate uncapped, and a deferred `play` that may resolve hidden. | TRACED | Release the active cell's surface when `isMovingFromParent`. Split `zoomTransitionDidEnd` into landed vs abandoned. |
| 2.6 | **Rotation during a flight** (decided 2026-10-03). | A process-wide "flight in progress" lease, taken at staging and released on every terminal branch, including the landing hold and the cover. The root's `supportedInterfaceOrientations` answers the current orientation while it is held; call `setNeedsUpdateOfSupportedInterfaceOrientations()` on release. |
| 2.5 | **A cancelled grab does not roll back source staging:** handoff retargeted, `adoptForClose`, the landing retry still demanding. | TRACED | `zoomSourceDidAbandonDismissal()` (a requirement), called on the cancel branches. |
| 2.7 | **The grab's release has no touch shield** (the tap-back has one). For about 0.5s touches reach the presenter, and a scroll or pan there makes the card land on a stale rect. | Add the shield at release and remove it in `finishTransition`. |
| 2.8 | **The landing retry window starts at grab STAGING, not at release** (0.42s). A held grab lands without the live picture, and the loan it demanded is left running. Same for a reversed or cancelled close: the demanded tile plays hidden under the feed until the final close. | Re-arm at release. On cancel or reversal, stop the demanded loan and retarget the handoff back (merged with 2.5). |
| 2.9 | **`zoomTransitionDidEnd` also runs on the DEPARTING feed after a completed dismissal.** `reclaimPlayback` rebinds the player to the feed view right after the landing tile adopted it, and the bitrate is uncapped. | Merged with 2.4: split into `landed` / `departed` / `abandoned`. |
| 2.10 | **The grid's inset freeze can outlive a cancelled grab** when the feed leaves by another route (pop-to-root, multi-pop). | `sweepAbandonedTransition` ends the freeze unconditionally. |
| 2.11 | **`cardPathFlight` is not cleared at a hero open or in the sweep**, so two live zoom drivers can sit on the reused view. | Merged into 2.3 (the recognizer/driver invalidation). |
| 2.12 | **Accessibility:** the parked cover and the chrome replica are exposed to VoiceOver for up to 3s, and no arrival posts `.screenChanged`. | Set `accessibilityElementsHidden` on every flight card; post `.screenChanged` with the arrival in `didShow` and after a reversal. |
| 2.13 | **`clearRecededChrome` writes defaults** (`cornerRadius 0`, `masksToBounds false`) instead of restoring the previous values. | Snapshot both in `applyRecededChrome` and restore them. |
| 2.14 | **Reveal staging goes stale after a re-anchor or a cancel.** The fill and corner radius are evaluated eagerly for the opening post, and the once-only latch never restages. | Make them closures over `anchorID`, or restage on every attempt with an idempotent adoption. |
| 2.15 | **The instrument that proves A + B: `ArrivalInvariants` (DEBUG).** It checks the arrival screen at didShow +2 ticks and again at +3.3s, past every ceiling. Generic checks: ancestors' alpha, hidden, interaction and transform; no flight leftovers under `nav.view`; nav idle; native chrome alpha 1; tab bar matching `TabBarRevealPolicy`; no dead-delegate recognizers; census at 0; accessibility. Screens add facts through `ArrivalInvariantReporting` (SnapFeed flags, Maps hidden markers/gate/sentinel, grid concealment/handoff). Census keys also go on the reveal grab driver, the slide dismissal and the retainers. | FAIL lines go into `hero-audit.log`, driven by the existing hero-qa args plus a new "close and reopen within 1s" case. |
| 2.16 | **Found while verifying PR A** (it is on develop too): after a PUSH caught and reversed (`-zoom-interrupt cancel`), For You's header glass buttons stay dimmed at rest. | **Root cause measured, fix deferred.** The bar's `NavigationBarPlatterContainer_v2` keeps two `_UIInheritedView` cross-fade layers frozen at the fraction the push was caught (0.21/0.79, 0.30/0.70 in two runs: model = presentation, no animation running). Reassigning the presenter's bar items (same arrays, or cleared and put back) does NOT rebuild them, so the fade lives in the platter container rather than in the items. UIKit-internal and cosmetic; needs its own investigation (what UIKit expects from a percent-driven cancel for the platter fade to run home). |


## PR B outcome (2026-10-03)

### Done
- **2.1 / 2.2:** `ZoomLandingLeftovers`. Covers and holds are leases. A new present, a close or grab beginning, `repoint`, or a drag on the feed ends them at once, and an ended cover adopts nothing.
- **2.3 / 2.11:** pan sweeping.
  - The dismissal pan is a marked `ZoomDismissPan`, and dead ones are swept at the next attach.
  - The interruptor's recognizers come off at `didShow` and on reversal.
  - For You drops a stale `cardPathFlight`.
- **2.4 / 2.9:** `zoomTransitionWillDepart()`, a new destination requirement. A page leaving with its flight no longer reclaims the player or starts a deferred clip.
- **2.5 / 2.8:** `zoomSourceDidAbandonDismissal()`, a new source requirement. On a cancelled or reversed close, the grid stops the landing retry and points the playback scope back at the page's post. The landing retry now lives as long as the card (ceiling 6s), not one spring.
- **2.6:** `FlightOrientationLock`. Flights, covers and holds take leases; the root container answers the current orientation while any is held. A 10s safety expiry covers transitions UIKit abandons.
- **2.7:** touch shield over a released grab. The grab's completion is captured strongly.
- **2.10:** the For You sweep thaws the inset unconditionally.
- **2.12:** flight twins are hidden from VoiceOver; `.screenChanged` is posted on arrival.
- **2.13:** receded chrome is restored from a snapshot.
- **2.15:** `ArrivalInvariants`, with SnapFeed and Maps reporting facts.

### Verified in the simulator under `-hero-audit`
Every arrival line is PASS, and the census settles to empty, on these scenarios:
- tap-back (`presented` → `returned`);
- reversed push;
- map pin round trip;
- map grab, cancel then commit (`grabCancelled`, `grabReturned`).

### Deferred
- **2.14 to PR C.** Making `TextRevealOrigin`'s eager values lazy touches FeedInterface and every caller, which PR C rebuilds anyway.
- **2.16 left open.** Root cause measured: the platter cross-fade is frozen inside UIKit, and rebuilding the bar items does not reach it.


## PR C outcome (2026-10-03)

### Done
- **3.0 `DismissalArbiter.heroCarries(kind:landingAcceptsHero:heroClaimsAxis:)`.** One pure rule, now asked from all six places:
  - the zoom grab's gate;
  - the chevron's pop;
  - the scripted grab;
  - the slide's begin gate;
  - the slide's `.hero` forwarding;
  - `closeCarriesCard`.

  The slide's forwarding branch now asks about the axis only while it is driving the drag itself; it used to ask `.horizontal` for a vertical hero grab.
- **3.1 `HeroPushSession`.** It builds and keeps the controller, leases the delegate slot (hands it back, or empties it for a tab root, only if the slot is still the session's or a registered forwarder's), and runs one idempotent close-out per ending (`returned`, `reversed`, `abandoned`, `toIntermediate`), releasing its objects a turn later. Migrated:
  - `FeedFeatureBuilder` (self-retained session);
  - For You's hero path;
  - For You's close-only text path;
  - Maps.

  The place page's map-return keeps its re-asserted lease pattern; it moves to PR D (the delegate hub).
- **Latent trap fixed:** the place page's close-only controller now passes `presents: false`.

### Rule reaffirmed by the user (2026-10-03)
The tab bar and toolbars are UIKit's, animation included. An overlap while UIKit animates is acceptable. `ArrivalInvariants` therefore judges the tab bar at rest only; its settled-phase check flagged UIKit's own fade, the same on PR B.

### Deferred
**2.14 → PR F.** The once-only staging latch would have to restage after a cancel, and the host's staging moves a grid slot (`adoptForClose`). Making that idempotent is not worth the risk for a cosmetic tint and corner mismatch on one sequence.


## PR D outcome (2026-10-03)

### What the hub does
`NavigationDelegateHub` is the one occupant of a stack's delegate slot. The
four remaining writers lease it:
- `HeroPushSession`;
- `InteractiveSlideDismissal`;
- the place page's map-return;
- the builder's grab re-take.

Rules:
- **Routing.** UIKit's questions go to the top lease alone, as they went to the single occupant. Leases still forward (a card close forwards a `.hero` pop to its flight).
- **Broadcast.** `didShow` goes to every live lease, bottom first, once each. A lease's own forwarding goes through `deliverDidShow`, which dedupes within a dispatch.
- **Release.** Releasing a lease uncovers the one below; nothing captured can be stale.
- **Direct writes.** A delegate written to the slot directly is adopted: at the bottom if it was there first, on top if written later.

### Removed
- `ZoomTransitionController.displacedDelegate`.
- `InteractiveSlideDismissal`'s displaced hand-off (from PR A 1.14), now structural.
- `HeroPushSession.handsSlotBack` and its previous-delegate capture.
- The place page's `mapReturnPreviousDelegate`.

### Added
- **`ZoomTransitionController` arrival edge.** It reads `onSourceReturned` only after having seen its feed on the stack (`hasSeenFeedOnStack`, the slide's rule). Close-only controllers start having seen it. Every lease now hears every `didShow`, so a premature one must not read as a return.
- **`UINavigationController.leasedDelegate`**, for tests and diagnostics.

## Phase 3: structure (behaviour-preserving refactors, one PR each)

**3.0 One dismissal arbiter.** The rule for which driver claims a drag is
written 4 times:
- the zoom driver's `shouldBegin`;
- the slide's `shouldBegin`;
- the slide's hero branch;
- `closeCarriesCard`.

`popAxis` is also asked about the wrong axis on a vertical hero grab. One pure
function, shared by all four, would fix both.

**3.1 `HeroPushSession` (CoreNavigation).** The "present a post by hero"
orchestration exists 3 times, and the copies have drifted:
- For You `openFeed`, about 460 lines;
- Maps `presentSnapFeed`, about 320 lines;
- `FeedFeatureBuilder.presentSnapFeedHero`, about 200 lines.

Plus two close-only variants. How they differ:
- `onPresentationCancelled`: 2 of 3 handle it.
- `onDismissalCancelled`: 1 of 3.
- Abandoned-flight sweep: 1 of 3.
- Tab bar: hidden 3 different ways.
- `prepareForHeroPresentation`: only For You.
- Grab begin: the builder re-takes the delegate slot; the others don't.

One session object would own all of it:
- building, retaining and invalidating the controller;
- the delegate lease;
- the card-close driver alongside;
- one idempotent `close(reason: .returned | .reversed | .abandoned)`.

Presenters pass hooks (`onClosed`, `onLanded`, extra dismissal targets).
Migrate the builder first (smallest), then For You, Maps and PlaceProfile.

**3.2 Navigation delegate ownership.** Today the slot is written by 5
presenters and by `InteractiveSlideDismissal`, and restored four different
ways, including an unconditional `= nil` (ForYou:1478/1500/2062,
Maps:3421/3464). Proposed:
- **`NavigationTransitionHub`**: installed once per navigation controller, as
  its permanent delegate.
- **Leases**: transitions take a token lease; the hub routes
  animation/interaction to the top lease and broadcasts `didShow` to every
  lease.
- **Removed**: `displacedDelegate`, `savedDelegate`, `previousDelegate`,
  `mapReturnPreviousDelegate` and the retainer cycle.
- This deletes a whole class of bug (the "stolen delegate / lost didShow"
  family has 3 entries in the memory notes).
- It is also the riskiest refactor here.

**3.3 `TransitionPlaybackSession` + identity-keyed pool APIs.** Today the
player is assigned during a flight in 5 places: grid `start`, feed JOIN,
URL-keyed `attachSurface`, `adoptSurface` at the cover gate, and
`transferOwnership` at the landing. URL keys are ambiguous as soon as two
players share an asset (JOIN co-owners, reposts):
- `transferOwnership` takes `first(where: url)`;
- `attachSurface(to:url)`;
- `setPeakBitRate(for:url)`.

The proposal:
- `PlayerToken`-keyed variants of those APIs.
- One session per flight (`begin`, `flightSurface`, `retarget`, `land(on:)`,
  `reclaim`, idempotent `end`).
- A DEBUG assert if it is deallocated without `end()`, which would have caught
  1.5 by itself.

**3.4 Dead seams.**
- The hoist API: 3 source requirements plus the animator branches. The only
  conformer passes `nil`.
- `adoptHostedSurface`/`hostedSurfaces`, `parkForHandoff`, and the dead
  `transferOwnership` call sites (Grid:751, 958).
- `zoomPrepareForPresentation`: no driver calls it. Either the session (3.1)
  calls it for every presenter, which gives Maps and the builder the measured
  pre-pay, or it is deleted.

**3.5 Protocol slimming** (optional):
- Move the ~8 live-media members into `ZoomLiveMediaHandoff`, so 6 conformers
  stop downcasting `UIView` to `VideoRenderView`.
- Move `concealsAppTabBar` to `AppTabBarConcealing`.
- Constrain the destination to `UIViewController`, so the silent `as?` at
  ZoomTransitionController.swift:119 goes away.

**3.6 File splits** (optional, mechanical):
- `ZoomAnimator` → present leg, dismiss leg, landing gates, and the DEBUG profiler.
- `SnapFeedViewController`'s ~1,200-line zoom extension → `SnapFeedZoomDestination`.
- ForYouGridPage's hero handoff/geometry (~1,500 lines) → `ForYouGridHeroController`.

**3.7 `DebugFlags`.** There are 416 uncached `ProcessInfo.arguments` reads,
several of them per frame (`poseFloating`, `cellForItemAt`, pill scrub). They
skew the DEBUG `-zoom-profile` numbers. Cache them as static lets, the
`VideoRenderFlags` pattern.

## Phase 4: fallbacks & accessibility

| # | Gap | Fix |
|---|---|---|
| 4.1 | **Reduce Motion is ignored by the hero** (VERIFIED). `GrabDeformation` and `SideDrawer` honour it. | **Decided:** native UIKit push/pop. Decide it at the presenter (once `HeroPushSession` exists, there is one decision point) and route through the existing no-flight path (`pushWithoutFlight`): no controller, no grab, native edge pop. With "Prefer Cross-Fade Transitions" on, UIKit dissolves its own pushes, so that setting is honoured for free. ⚠️ Returning nil from `animationControllerFor` is NOT enough: `zoomTransitionWillBegin` already ran in the controller's init, and the page would defer its playback forever. |
| 4.2 | **The centred fallback lands as an opaque pin in the middle of the screen**, then pops off. An off-screen video tile holds it for the full 0.75s. | When `!zoomSourceIsOnScreen` at staging: fade card and shadow to 0 in the pose block and skip the hold. |
| 4.3 | **No `isFinite` validation of rects** (NaN/inf/empty source rect). | `sanitized(in:)` maps such rects to `centeredFallback`. |
| 4.4 | **A deep link or route during a flight is silently dropped** by UIKit. `FeedFlowCoordinator` has already hidden the tab bar and installed its slide dismissal. | Defer the route until `transitionCoordinator` completes. |
| 4.5 | **Rotation:** iPhone allows landscape (pbxproj:334); the hero ignores size changes. | **Decided, moved to PR B (2.6):** lock rotation for the length of a flight. |
| 4.6 | *(moved to PR A as 1.24)* | |

## Phase 5: tests & QA

- **Animator-level unit harness:** a stub source/destination plus a fake
  `UIViewControllerContextTransitioning`, so terminal branches can be tested
  directly:
  - off-screen source;
  - zero target;
  - reversed flight;
  - the 3 ceilings tripping, with an injectable clock for
    `whenReady`/`holdCard`.
- **`ZoomExistentialDispatchTests`:** add `zoomLandingAcceptsHero`,
  `fadeInAdoptedLiveMedia(over:)` and `zoomLiveMediaDidStall()`.
- **New hero-qa / UI cases:**
  - pin removed while the feed is open (off-screen landing);
  - hydration ceiling (`-mock-latency 4000`, `-mock-fail PostService`);
  - re-open inside the cover window (2.1);
  - double tap;
  - tab switch while a finger holds a flight (1.1);
  - background mid-flight.
- **Census keys:** grab pans, interruptor recognizers and ready gates, so
  `HeroTransitionAudit` sees 2.3-type leaks.
- **Repros before fixing:** 1.1, 1.3 and 2.1 get a simulator repro, run one
  sim at a time, before the fix lands.

## Order (validated 2026-10-03: one PR per letter)

1. **PR A**: Phase 1 (12 fixes, each with a test).
2. **PR B**: Phase 2 (cover/hold/recognizer lifetimes).
3. **PR C**: 3.1 `HeroPushSession`, which absorbs 1.4's class of drift.
4. **PR D**: 3.2 the delegate hub.
5. **PR E**: 3.3 the playback session plus identity-keyed pool APIs.
6. **PR F**: 3.4 dead seams, plus Phase 4.
7. **Optional**: 3.5–3.7.

Phase 5 tests ride along with each PR. Each PR is verified on the sim through
`/verify` and the `Scripts/hero-qa` run.
