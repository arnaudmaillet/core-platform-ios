# Where the map's pan/zoom cost actually is

Analysis only — nothing here is implemented. iPhone 17 Pro Max simulator,
scripted pan+zoom (`-maps-nav-sweep`, `setRegion(animated:)` every 1.4 s).

## The measurements

| Configuration | Markers | CPU | Frame mean | p95 | Hitches /2 s |
|---|---|---|---|---|---|
| Clustered, **static** | 19 | 14.9 % | 16.67 ms | 16.67 | **0.00** |
| Clustered, sweeping | 26 | 46.5 % | 20.63 ms | 36.88 | 21.8 |
| Unclustered, sweeping | 159 | 38.5 % | 43.92 ms | 75.86 | 87.9 |

Standing still, the map is a locked 60 fps with every sheet and icon animating.
**100 % of the cost is region changes.**

Animation is not it, measured on both paths:

| | CPU | Frame mean | Hitches |
|---|---|---|---|
| unclustered, animating | 31.1 % | 47.01 ms | 87.5 |
| unclustered, no animation at all | 29.3 % | 45.37 ms | 84.4 |
| clustered, animating | 46.7 % | 22.36 ms | 31.9 |
| clustered, no animation at all | 43.3 % | **23.24 ms** | **35.1** |

On both paths the *still* arm is marginally **worse** on frame time and hitches.

## The negative result that matters

A sub-analysis transcribed `MapClusterEngine.proximityCluster` into a standalone
binary and measured its restart-on-every-merge loop at **26.17 ms under `-Onone`
and 0.162 ms under `-O`** — a 160× ratio — and concluded the O(m·n²) merge was
the prime cost centre. A second pass argued the opposite: that the whole
clustering signal is a `-Onone` artifact that vanishes in a shipping build.

Both are wrong. Rebuilt with `SWIFT_OPTIMIZATION_LEVEL=-O
SWIFT_COMPILATION_MODE=wholemodule`, `DEBUG` still defined so the HUD survives:

| | `-Onone` | `-O wholemodule` |
|---|---|---|
| clustered d60 | 45.8 % / 20.61 ms / 22.3 | 46.5 % / 20.63 ms / 21.8 |
| unclustered d60 | 33.9 % / 41.06 ms / 85.0 | 38.5 % / 43.92 ms / 87.9 |

Identical within noise; the optimised unclustered arm is slightly worse.
**Making the merge arithmetic 160× faster changed nothing measurable**, so the
merge is not what the CPU is being spent on — and the clustering delta is real,
not a Debug artifact.

## What is left, by elimination

Excluded by measurement: animation, sprite-sheet stepping, icon tracks, and the
clustering arithmetic itself. What remains inside a region change:

1. **MapKit's own region and tile work.** Bounded below by the no-animation arm:
   45.37 ms and 84.4 hitches at ~200 markers with everything switched off.
   Nothing in this codebase reaches it.
2. **Annotation population churn.** The leading hypothesis for the clustered
   path's inverted cost — 6× fewer markers, 2× better frames, yet *more* CPU.
   Every zoom step merges or splits clusters, so annotation views are realised
   and released continuously, each arrival paying view realisation, a
   `UIViewPropertyAnimator` pop, an artwork rebind and possibly a decode.
   Unclustered markers are stable identities that merely move.

⚠️ Point 2 is **not confirmed**. Confirming it needs an add/remove counter per
region change, which does not exist yet. It should be built before any of the
work below is scheduled.

## The counter was built, and it refuted the hypothesis

`MapChurnCounters` (DEBUG) counts what a region change actually does, splitting
`configure` calls that passed the idempotence guard (`bound`) from those that
returned on it (`skipped`) — counting their sum would have reported "hundreds of
rebinds" about a path that mostly does nothing.

| | markers | reconcile/s | add/s | out/s | viewFor/s | bound/s | skipped/s | CPU | frame | hitch |
|---|---|---|---|---|---|---|---|---|---|---|
| clustered, static | 19 | **0.00** | 0 | 0 | 0 | 0 | 0 | 11.2 % | 16.68 | 0.1 |
| clustered, sweep | 26 | 1.44 | 10.7 | 11.0 | 10.3 | 15.3 | 15.5 | 44.4 % | 20.38 | 19.3 |
| unclustered, sweep | 159 | 1.46 | 27.5 | 27.5 | 28.6 | 28.6 | 180.4 | 33.4 % | 37.84 | 79.1 |

**The churn hypothesis is dead.** The clustered arm churns roughly 2.5× LESS
(10.7 arrivals/s against 27.5) and costs 11 CPU points MORE. Churn cannot explain
the clustered path's cost because it moves the wrong way.

Two things it did settle:

- **Static reconciles are exactly zero.** 100 % of the cost is region changes,
  now by direct count rather than inference.
- **The double reconcile is real.** 1.42–1.46 reconciles/s against a region
  change every 1.4 s (0.71/s) is exactly 2×. This resolves the contradiction
  between the two sub-analyses in favour of the one that measured it.

## And then reconcile duration killed the whole framing

| | reconcile/s | total ms/s | mean | worst |
|---|---|---|---|---|
| clustered, sweep | 1.42 | **6.73 ms/s** | 4.75 ms | 17.69 ms |
| unclustered, sweep | 1.45 | **6.78 ms/s** | 4.68 ms | 24.84 ms |

Reconcile costs **0.67 % of the main thread**, and it is identical in both arms.
Everything downstream of `reconcileClusters` — the merge, the tracker, the sort,
the rebinds, the churn — together fits inside 6.7 ms per second. **There is
essentially nothing there to win.**

## Re-reading the CPU column

The clustered arm has fewer markers, less churn, identical reconcile cost, and
higher CPU%. The consistent reading is that **CPU% is a rate, not a total**: the
unclustered arm at 38.97 ms/frame is not doing less work, it is doing the same
work across half as many frames while blocked on compositing 159 marker layers.
Lower CPU% with worse frames is what GPU-bound looks like. If that is right, the
"clustering costs 12 CPU points" framing from the earlier round is an artifact of
the metric, and **frame time and hitches are the only honest columns**.
⚠️ Untested — the simulator does not model TBDR, so this wants a device.

## Options, ranked by evidence rather than appeal

**1. Coalesce reconciles per region settle** — BUILT AND REJECTED, see above. It
removes 73 % of the reconcile time and costs 7 hitches /2 s. The double reconcile is now confirmed (1.42/s against 0.71
region-changes/s). Replace the inline `reconcileClusters()` in
`regionDidChangeAnimated` with a cancel-and-reschedule work item mirroring
`scheduleQuery`. Removes ~3.4 ms/s of main-thread work and one bursty stall per
settle — and the burst is the part that matters: a single 17.69 ms reconcile
drops a frame outright, where the 4.75 ms mean never would. Expect a few hitches
back, not a fix.

**2. Memoise the layout on `(pinsVersion, snappedZoom, activeKind)`** — now NOT
recommended. The mechanism is sound and the engine is provably pan-invariant, but
the entire budget it competes for is 6.7 ms/s. Best case it removes half of that:
~3 ms/s, for a medium-effort change whose failure mode is a map frozen on a stale
layout — the hardest class of bug to see in a screenshot. Bad trade.
⚠️ The rig cannot even measure it: under `-maps-mock-density > 1` the fixture
re-derives every clone's coordinate from the queried viewport, so the whole
corpus lands in `diff.updated` and the key misses 100 % of the time.

**3. Attack population churn** — dead. Measured above: the cheaper arm churns
2.5× more.

**4. Level of detail during camera flight.** The only option left with a
mechanism that reaches the actual cost (compositing and MapKit's region work),
and the only one that could move a 38.97 ms frame. ⚠️ It is a product decision,
not a technical one: it contradicts the standing rule that every icon animates
continuously, and the `didAdd` comment argues the pop is what makes the map feel
populated rather than stamped. Do not schedule it off the back of simulator
numbers.

## The throttle was built, measured, and is OFF

`-maps-nav-sweep` calls `setRegion(animated:)`, which fires
`regionDidChangeAnimated` **once per gesture**. A finger fires it once per
frame. `-maps-nav-drag` (60 Hz stepped pan, 1.0 s moving / 0.5 s still) is the
driver that can see the difference, and it changes the picture completely:

| driver | reconcile/s | reconcile ms/s | arrivals/s | rebinds/s |
|---|---|---|---|---|
| `-maps-nav-sweep` | 1.42 | 6.73 | 11.1 | 15.3 |
| `-maps-nav-drag` | 37.2 | **48.8** | 2.7 | ~0 |

Under a real pan the reconcile budget is **4.9 % of the main thread, not
0.67 %**, and it produces almost nothing. So the throttle was implemented: the
settle path defers while the SNAPPED ZOOM is unchanged, arming one trailing item
so it defers without ever dropping.

Three paired 60-second runs, fresh launch per arm:

| n=3 | reconcile/s | ms/s | CPU | frame | p95 | hitches /2 s |
|---|---|---|---|---|---|---|
| control | 37.21 | 48.83 | 48.5 % | 21.13 | 38.58 | **20.87** |
| throttled | 7.82 | **13.30** | 46.4 % | 22.01 | 40.46 | **28.23** |

**It works and it makes things worse.** 79 % of reconciles and 73 % of their
main-thread time removed, tight across all three reps — and the frame, the p95
and the hitch count all regress, with every throttled rep above the control's
mean. Removing 35 ms/s of main-thread work made the map stutter more.

The likely mechanism is **when**, not how much: the inline reconciles ran
synchronously inside the region-change callback, a moment the frame had already
conceded, while the trailing `asyncAfter` lands at an arbitrary point that can be
mid-frame. At 1.3 ms apiece, scheduling dominates volume.

It ships **disabled** (`-maps-reconcile-throttle` to enable), because the
experiment is worth keeping and the regression is not.

### Three ways this nearly shipped as a win

- The first predicate compared `MKCoordinateSpan` with `==`. `MKMapView` fits
  whatever span you hand `setRegion` to the view's aspect ratio, so it is never
  bit-identical and the throttle fired **zero** times — which read as "the
  optimisation does nothing" rather than "the predicate is broken".
- The trailing item was cancel-and-rescheduled, i.e. a debounce. Under a 60 Hz
  pan it was cancelled every 16 ms and never fired, so the map held **zero
  markers** while every performance column improved.
- The drag driver never stopped moving, so `scheduleQuery`'s settle debounce
  (correctly) never fired and no pins ever loaded. This appeared only *after*
  the throttle made settles cheap enough to sustain 60 Hz from launch — **the
  optimisation was fast enough to starve the app's own query.**
- And one paired run showed hitches 30.9 → 17.2, a 44 % win. The control arm
  alone swings 17.4–27.7 between runs. One pair could not have told them apart.

## Recommendation

**Do nothing. The debounce was built and measured, and it is a regression.**

Everything the codebase controls on this path fits in 6.7 ms per second. The
remaining ~14 ms of the clustered frame and ~22 ms of the unclustered one are
MapKit's own region and tile work plus compositing, bounded by the
no-animation-at-all arm at 45.37 ms. No proposal in this document reaches it, and
several of the earlier ones would have spent medium effort to win back tenths of
a millisecond.

The shipping configuration is **21.3 ms and 23 hitches /2 s under a driver that
fires a `setRegion(animated:)` every 1.4 s** — harsher than any human pan — and a
**perfect 60 fps with zero hitches standing still**. That is not a performance
problem that justifies restructuring the map.

Before any further work: measure on a device with Instruments. The frame time
here is most likely GPU/compositing-bound, and the simulator models neither TBDR
nor Metal texture memory, so it is the wrong instrument for the one cost that
actually dominates.

## Ruled out by mechanism

- **Moving clustering off the main actor** — the arithmetic is not the cost
  (the `-O` result above), so relocating it buys nothing. Doubly dead now:
  the whole reconcile is 0.67 % of the main thread.
- **Shadow paths, layer-count reduction, lazy per-face subtrees** — all below the
  noise floor of the only instrument that can see them; several are not on the
  measured path at all (`setRing` is never called on a plain `MapAnnotationView`;
  the reuse pool is a one-time warm, not a per-zoom cost).
- **Delta-only marker updates / skipping unchanged `configure`** — the guards
  already exist (`MapAnnotationView.swift:140`,
  `MapClusterAnnotationView.swift:128`) and already fire.

## Caveats

Simulator, and the sweep is harsher than a human pan (a `setRegion(animated:)`
every 1.4 s). It is a comparative instrument. The whole analysis wants re-running
on a device with Instruments before anything is scheduled.
