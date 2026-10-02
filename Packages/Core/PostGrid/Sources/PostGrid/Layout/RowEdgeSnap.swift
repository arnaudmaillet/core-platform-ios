import CoreGraphics

/// Where a horizontal strip of items comes to rest when the finger lets go —
/// the GESTURE'S DIRECTION decides (the product call of 2026-09-29, made for
/// For You's rows and carried to a card's media carousel on 2026-10-02):
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
/// the strip's own margins make offset 0 an item's leading edge on the left
/// margin, and the far end an item's trailing edge on the right one.
///
/// **Which item.** Forward, the one the projected rest cuts at the right
/// margin: the FIRST trailing anchor at or past where UIKit would have
/// stopped, so the item that was peeking comes all the way in — a nudge
/// reveals the next item, a fling the one it would have left cropped. Back is
/// the mirror: the LAST leading anchor at or before the projection. Never the
/// nearest: a nearest-anchor snap sends a short forward swipe BACK to where it
/// started, which is the strip refusing the finger.
///
/// **"Nothing on the hidden side" is geometry, not this function's doing.**
/// An item flush with one margin leaves its neighbour `gap - margin` points
/// off that edge, so a strip keeps its gap at least its margin
/// (`ForYouRailsView.Metrics.itemGap`; a carousel inside its box has a margin
/// of zero, so any gap does).
///
/// Pure, so it is tested without a scroll view. Lived in Feed as
/// `ForYouRowSnap` until the card carousel needed the same rule — moved here
/// rather than copied, because twins drift.
public enum RowEdgeSnap {
    public enum Direction: Equatable, Sendable {
        /// Towards the end of the strip — the finger moving LEFT.
        case forward
        /// Towards its start — the finger moving RIGHT.
        case backward
    }

    /// Below this release speed (points per millisecond, UIKit's unit for
    /// `withVelocity`) the lift is a stop, not a flick, and the drag's own
    /// last movement says which way the viewer meant.
    public static let flickVelocity: CGFloat = 0.1

    /// Half a point of slack: a rest a hair short of an anchor it is already
    /// resting on is on it.
    static let slack: CGFloat = 0.5

    /// The direction a release means: its velocity when it has one; else the
    /// drag's last movement (a slow drag lifted from a standstill still said
    /// which way it was going); else none, and the strip takes the nearest rest.
    public static func direction(velocity: CGFloat, lastMovement: Direction?) -> Direction? {
        if velocity > flickVelocity { return .forward }
        if velocity < -flickVelocity { return .backward }
        return lastMovement
    }

    /// Every offset an item's LEADING edge sits on the left margin at, plus
    /// the start — clamped into the scrollable range.
    public static func leadingAnchors(
        items: [ClosedRange<CGFloat>], margin: CGFloat, offsets: ClosedRange<CGFloat>
    ) -> [CGFloat] {
        items.map { clamp($0.lowerBound - margin, to: offsets) } + [offsets.lowerBound]
    }

    /// Every offset an item's TRAILING edge sits on the right margin at, plus
    /// the end — clamped into the scrollable range.
    public static func trailingAnchors(
        items: [ClosedRange<CGFloat>], viewport: CGFloat, margin: CGFloat,
        offsets: ClosedRange<CGFloat>
    ) -> [CGFloat] {
        items.map { clamp($0.upperBound + margin - viewport, to: offsets) } + [offsets.upperBound]
    }

    /// The content offset (x) to rest at.
    ///
    /// - Parameters:
    ///   - projected: where UIKit's deceleration would have stopped.
    ///   - direction: `direction(velocity:lastMovement:)`; nil takes the
    ///     nearest of every anchor.
    ///   - items: each item's frame's horizontal extent, in content space.
    ///   - viewport: the strip's visible width.
    ///   - margin: the side margin an item lines up on.
    ///   - offsets: the strip's scrollable range.
    public static func target(
        projected: CGFloat,
        direction: Direction?,
        items: [ClosedRange<CGFloat>],
        viewport: CGFloat,
        margin: CGFloat,
        offsets: ClosedRange<CGFloat>
    ) -> CGFloat {
        let leading = leadingAnchors(items: items, margin: margin, offsets: offsets)
        let trailing = trailingAnchors(items: items, viewport: viewport, margin: margin, offsets: offsets)
        let rest = clamp(projected, to: offsets)
        switch direction {
        case .forward:
            return trailing.filter { $0 >= rest - slack }.min() ?? offsets.upperBound
        case .backward:
            return leading.filter { $0 <= rest + slack }.max() ?? offsets.lowerBound
        case nil:
            return (leading + trailing).min { abs($0 - rest) < abs($1 - rest) } ?? rest
        }
    }

    /// The same edges, ONE STEP AT A TIME — the card carousel's variant.
    ///
    /// ⚠️ MOMENTUM DECIDES HOW FAST, NEVER HOW FAR. A card's carousel has
    /// always moved one picture per gesture ("if I slide hard I scroll
    /// several photos at once" was a defect report, not a wish), so the
    /// projection is ignored: the rest is decided from where the finger let
    /// go (`live`), the item it left cropped coming all the way in — and at
    /// least one item past where the drag BEGAN (`start`), so a short flick
    /// from a rest still moves. A long slow drag is honoured: the finger
    /// carried the strip there itself.
    public static func steppedTarget(
        live: CGFloat,
        start: CGFloat,
        direction: Direction?,
        items: [ClosedRange<CGFloat>],
        viewport: CGFloat,
        margin: CGFloat,
        offsets: ClosedRange<CGFloat>
    ) -> CGFloat {
        let leading = leadingAnchors(items: items, margin: margin, offsets: offsets)
        let trailing = trailingAnchors(items: items, viewport: viewport, margin: margin, offsets: offsets)
        let rest = clamp(live, to: offsets)
        let origin = clamp(start, to: offsets)
        switch direction {
        case .forward:
            let floor = max(rest - slack, origin + slack)
            return trailing.filter { $0 >= floor }.min() ?? offsets.upperBound
        case .backward:
            let ceiling = min(rest + slack, origin - slack)
            return leading.filter { $0 <= ceiling }.max() ?? offsets.lowerBound
        case nil:
            return (leading + trailing).min { abs($0 - rest) < abs($1 - rest) } ?? rest
        }
    }

    static func clamp(_ x: CGFloat, to offsets: ClosedRange<CGFloat>) -> CGFloat {
        min(max(x, offsets.lowerBound), offsets.upperBound)
    }
}

/// Which way a drag last MOVED — what a release with no speed left is read
/// by.
///
/// Not the net displacement since the touch began: a viewer who drags forward
/// and then eases back has changed their mind, and the strip should follow
/// the second thought. Not the last scroll tick either: a finger holding still
/// jitters by fractions of a point both ways. A movement counts once it has
/// run `threshold` points the same way.
public struct RowEdgeDragTracker: Equatable, Sendable {
    public static let threshold: CGFloat = 2

    public private(set) var lastMovement: RowEdgeSnap.Direction?
    /// Where the drag began — the offset `RowEdgeSnap.steppedTarget` measures
    /// its one step from.
    public let start: CGFloat
    private var runStart: CGFloat
    private var runDirection: RowEdgeSnap.Direction?
    private var previous: CGFloat

    /// A drag starts at `offset`, with nothing said yet.
    public init(offset: CGFloat) {
        start = offset
        runStart = offset
        previous = offset
    }

    /// The strip scrolled to `offset` under the finger.
    public mutating func track(_ offset: CGFloat) {
        defer { previous = offset }
        guard offset != previous else { return }
        let direction: RowEdgeSnap.Direction = offset > previous ? .forward : .backward
        if direction != runDirection {
            runDirection = direction
            runStart = previous
        }
        if abs(offset - runStart) >= Self.threshold { lastMovement = direction }
    }
}
