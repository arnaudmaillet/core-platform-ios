import PostGrid

/// Where one of For You's rows comes to rest when the finger lets go — the
/// gesture's direction picks the edge an item lands on (2026-09-29). The rule
/// lives in PostGrid as `RowEdgeSnap` since a card's media carousel snaps by
/// it too; these names are the rows' own, kept so the rows read as before.
typealias ForYouRowSnap = RowEdgeSnap

/// Which way a row's drag last moved — see `RowEdgeDragTracker`.
typealias ForYouRowDragTracker = RowEdgeDragTracker
