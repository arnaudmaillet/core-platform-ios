# 0015. Map clustering is computed by the app, not by MapKit

Date: 2026-07-24 · Status: Accepted · PR: #65

## Context
`MKMapView`'s built-in clustering degrades across pan and zoom: once annotation views exist, it runs only an incremental pass that skips them, so after a few zooms most pins stop grouping. It was measured on an annotation set that never changed (80 pins, 57 stacked after about ten navigation actions), so no way of feeding it escapes the defect.

## Decision
- **`MapClusterEngine` (Maps) computes the clusters**: it grids pins by a screen-space cell, then merges any two nodes closer than a cell (Chebyshev distance). It is pure and takes a projection scale, not a live map.
- **The map is handed exactly the markers to draw**: lone pins and one representative per group. **No annotation sets `clusteringIdentifier`**, so MapKit never runs its own pass.

## Consequences
- No overlaps at any zoom and no accumulation across navigation, unit-tested by `MapClusterEngineTests`.
- The app owns marker appearance and disappearance (`reconcileClusters`), including the fade-out of a marker that leaves.
- Re-enabling MapKit's clustering would bring the defect back.
