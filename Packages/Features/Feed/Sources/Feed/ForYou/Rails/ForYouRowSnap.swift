import CoreGraphics

/// Where one of For You's rows comes to rest when the finger lets go — the
/// GESTURE'S DIRECTION decides (the product call of 2026-09-29):
///
/// ```
///   forward (swiping left)            back (swiping right)
///   ┐ ┌──────┐ ┌──────┐ │             │ ┌──────┐ ┌──────┐ ┌──
///   │ │      │ │      │ │             │ │      │ │      │ │
///   ┘ └──────┘ └──────┘ │             │ └──────┘ └──────┘ └──
///     an item's TRAILING edge on      an item's LEADING edge on
///     the right margin: the one       the left margin: the one
///     before it peeks on the left,    after it peeks on the right,
///     nothing on the right            nothing on the left
/// ```
///
/// The start is always the leading case and the end always the trailing one:
/// the section's own margins make offset 0 an item's leading edge on the left
/// margin, and the far end an item's trailing edge on the right one.
///
/// **Which item.** Forward, the one the projected rest cuts at the right
/// margin: the FIRST trailing anchor at or past where UIKit would have
/// stopped, so the item that was peeking comes all the way in — a nudge
/// reveals the next item, a fling the one it would have left cropped. Back is
/// the mirror: the LAST leading anchor at or before the projection. Never the
/// nearest: a nearest-anchor snap sends a short forward swipe BACK to where it
/// started, which is the row refusing the finger.
///
/// **"Nothing on the hidden side" is geometry, not this function's doing.**
/// An item flush with one margin leaves its neighbour `gap - margin` points
/// off that edge of the screen, so the rows keep their gap at least their
/// margin (`ForYouRailsView.Metrics.itemGap`).
///
/// Pure, so it is tested without a scroll view; `ForYouRailsView` feeds it
/// from `scrollViewWillEndDragging`.
enum ForYouRowSnap {
    enum Direction: Equatable {
        /// Towards the end of the row — the finger moving LEFT.
        case forward
        /// Towards its start — the finger moving RIGHT.
        case backward
    }

    /// Below this release speed (points per millisecond, UIKit's unit for
    /// `withVelocity`) the lift is a stop, not a flick, and the drag's own
    /// last movement says which way the viewer meant.
    static let flickVelocity: CGFloat = 0.1

    /// The direction a release means: its velocity when it has one; else the
    /// drag's last movement (a slow drag lifted from a standstill still said
    /// which way it was going); else none, and the row takes the nearest rest.
    static func direction(velocity: CGFloat, lastMovement: Direction?) -> Direction? {
        if velocity > flickVelocity { return .forward }
        if velocity < -flickVelocity { return .backward }
        return lastMovement
    }

    /// The content offset (x) to rest at.
    ///
    /// - Parameters:
    ///   - projected: where UIKit's deceleration would have stopped.
    ///   - direction: `direction(velocity:lastMovement:)`; nil takes the
    ///     nearest of every anchor.
    ///   - items: each item's frame's horizontal extent, in content space.
    ///   - viewport: the row's visible width.
    ///   - margin: the side margin an item lines up on.
    ///   - offsets: the row's scrollable range.
    static func target(
        projected: CGFloat,
        direction: Direction?,
        items: [ClosedRange<CGFloat>],
        viewport: CGFloat,
        margin: CGFloat,
        offsets: ClosedRange<CGFloat>
    ) -> CGFloat {
        func clamp(_ x: CGFloat) -> CGFloat { min(max(x, offsets.lowerBound), offsets.upperBound) }
        // Half a point of slack: a projection a hair short of an anchor it is
        // already resting on is on it.
        let slack: CGFloat = 0.5
        let leading = items.map { clamp($0.lowerBound - margin) } + [offsets.lowerBound]
        let trailing = items.map { clamp($0.upperBound + margin - viewport) } + [offsets.upperBound]
        let rest = clamp(projected)
        switch direction {
        case .forward:
            return trailing.filter { $0 >= rest - slack }.min() ?? offsets.upperBound
        case .backward:
            return leading.filter { $0 <= rest + slack }.max() ?? offsets.lowerBound
        case nil:
            return (leading + trailing).min { abs($0 - rest) < abs($1 - rest) } ?? rest
        }
    }
}

/// Which way a drag last MOVED — what a release with no speed left is read
/// by.
///
/// Not the net displacement since the touch began: a viewer who drags forward
/// and then eases back has changed their mind, and the row should follow the
/// second thought. Not the last scroll tick either: a finger holding still
/// jitters by fractions of a point both ways. A movement counts once it has
/// run `threshold` points the same way.
struct ForYouRowDragTracker: Equatable {
    static let threshold: CGFloat = 2

    private(set) var lastMovement: ForYouRowSnap.Direction?
    private var runStart: CGFloat
    private var runDirection: ForYouRowSnap.Direction?
    private var previous: CGFloat

    /// A drag starts at `offset`, with nothing said yet.
    init(offset: CGFloat) {
        runStart = offset
        previous = offset
    }

    /// The row scrolled to `offset` under the finger.
    mutating func track(_ offset: CGFloat) {
        defer { previous = offset }
        guard offset != previous else { return }
        let direction: ForYouRowSnap.Direction = offset > previous ? .forward : .backward
        if direction != runDirection {
            runDirection = direction
            runStart = previous
        }
        if abs(offset - runStart) >= Self.threshold { lastMovement = direction }
    }
}
