# Sprite-sheet marker previews: the worst case, measured

iPhone 17 Pro Max simulator, Debug, `-rich-media`. Every figure below is the
mean over a ~45 s window after the first 12 samples are discarded (launch,
first decode and the initial region settle all land in those).

## What "128 annotations" actually means

**The shipping map cannot produce 128 markers.** `MapClusterEngine`'s proximity
merge recomputes each cluster's centroid, so merges chain: a denser corpus
collapses harder instead of packing the lattice. Measured peak marker counts
under the same driver:

| Configuration | Peak markers |
|---|---|
| Shipping, default mock density | 13 |
| Shipping, `-maps-mock-density 60` | 54 |
| `-maps-no-clustering`, pitch 46 | 144 static / 204 under sweep |
| `-maps-no-clustering`, pitch 26 | 464 |

128 is a **geometric bound** — the number of 44 pt faces that tile a phone
screen — not a state the engine reaches. `-maps-no-clustering` (DEBUG only)
exists solely to stand a field that size in front of the real renderer; it
routes singles through the same reconciliation path, so what it measures is the
real marker lifecycle.

`-maps-mock-pitch` was clamped `max(64, …)`, a guard against laying pins closer
than the 64 pt merge threshold. Correct while clustering was on, and exactly
wrong once the bypass existed: three consecutive runs at pitch 64/45/32 all
reported the same 66 markers because they were all pitch 64. Floor is now 16.

## The measurement had to be repaired first

`sheets=N` in the HUD counted `wornPreview != nil` — **art handed to the view**,
not art advancing. A field reporting "80 sheets playing" said nothing about
whether a single frame had stepped. `sheets_advancing` now counts sheets whose
presentation-layer `contentsRect` fingerprint *changed* between two samples one
second apart, against a 125 ms frame step. With that probe: **80 of 80** and
**67 of 67** advancing. The animation is real.

## Result: at 200 markers, the animation is free

Same 1.4 s scripted pan+zoom sweep, `-maps-no-clustering -maps-mock-pitch 46`:

| Arm | Sheets advancing | CPU | Frame mean | p95 | Hitches /2 s | Peak footprint |
|---|---|---|---|---|---|---|
| A — sheets + icons | 73.3 | 31.1 % | 47.01 ms | 79.70 ms | 87.5 | 279 MB |
| B — icons only | 0 | 29.8 % | 47.90 ms | 83.77 ms | 89.0 | 230 MB |
| C — no animation at all | 0 | 29.3 % | 45.37 ms | 83.57 ms | 84.4 | 207 MB |

73 advancing sprite sheets cost **+1.6 ms of frame mean and +1.8 points of CPU
over animating nothing**. Arm B, which animates *less* than A, measured
marginally worse on every timing column — the three arms are one population.

The 45 ms frames and 88 hitches are **navigation**, and they are already there
with zero animation running. This restates what the icon work found and extends
it to the preview path: reconciliation and annotation-view churn are binding,
animation is not.

Corroborating: the shipping map burns **more** CPU at 54 markers (43.1 %) than
the bypass does at 204 (31.1 %). The merge is the expense, not the marker count.

Static field, no navigation, 144 markers (80 sheets + 48 icons):
**16.73 ms mean, p95 16.67, 0.21 hitches /2 s, CPU 17.6 %, 140 MB.** A locked
60 fps.

## Where sheets do cost: memory

+72 MB of peak footprint over the still arm, +49 MB over icons-only. Residency
stays at 7–9 sheets (19.0–24.4 MB) against the 64 MB budget across every run,
including the 464-marker field — eviction holds, and it holds because the
catalogue is byte-budgeted rather than count-budgeted. 24 distinct sheets is
4.8 MB on the wire and 65.0 MB if all were resident at once, so full variety
guarantees eviction by design.

## Caveats

- The sweep issues `setRegion(animated: true)` every 1.4 s — continuous animated
  camera motion, harsher than a human panning. It is a **comparative** driver:
  valid for the A/B above, not an absolute product verdict. Even 13 shipping
  markers show 9 hitches /2 s under it.
- Simulator. It does not model the hardware decode-session budget, TBDR
  offscreen passes, or Metal texture memory. The memory column in particular
  should be re-read on a device.
- `-maps-mock-density` and `-maps-mock-pitch` are calibrated against a 440×956
  reference screen.
