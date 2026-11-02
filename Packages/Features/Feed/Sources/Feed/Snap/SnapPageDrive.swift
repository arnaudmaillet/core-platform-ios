import CoreGraphics

/// The hand-driven page swipe's arithmetic (#2056, #2058): the drive that
/// pages a text page and an engaged media page — the composer's pan and the
/// header band's, where the pager itself is disabled.
///
/// ⚠️ BOTH WAYS (the owner, 2026-11-02). Forward-only since #114, a downward
/// drive settled home; it now steps to the previous post, down to the
/// first, which no drive passes: on the first post the downward drag is the
/// dismissal's (`SnapVerticalDragRouter`), and the drive rubber-bands.
///
/// Pure, for tests (`SnapPageDriveTests`).
enum SnapPageDrive {
    /// How far a drag must travel, in pages, to commit without a fling.
    static let commitDistance: CGFloat = 0.18
    /// How fast a fling commits, whatever the distance (pt/s).
    static let commitVelocity: CGFloat = 500
    /// The slice of velocity the projection adds to the drag.
    static let projection: CGFloat = 0.2

    /// The step a release commits: +1 (the next post) for a drag up whose
    /// projection (the drag and a slice of its velocity) is still up, −1
    /// (the previous one) for the same downward, 0 when it was neither far
    /// nor fast enough — or when the finger turned back: a drag up flung
    /// down settles HOME, never a page the other way. A drag up is a
    /// negative `dy`.
    static func step(translation dy: CGFloat, velocity vy: CGFloat, page: CGFloat) -> Int {
        let committed = abs(dy) > page * commitDistance || abs(vy) > commitVelocity
        guard committed else { return 0 }
        let projected = dy + vy * projection
        // A fling from rest: its velocity alone says which way.
        let heading = abs(dy) < 1 ? projected : dy
        if heading < 0, projected < 0 { return 1 }
        if heading > 0, projected > 0 { return -1 }
        return 0
    }

    /// The lowest page a drive from `origin` may reach: the previous post,
    /// never past the first.
    static func floorIndex(origin: Int) -> Int {
        max(0, origin - 1)
    }

    /// The page a release settles on: `origin` moved by `step`, held between
    /// the first post and `ceiling` (the last page that is ready).
    static func target(origin: Int, step: Int, ceiling: Int) -> Int {
        min(max(floorIndex(origin: origin), origin + step), max(origin, ceiling))
    }
}
