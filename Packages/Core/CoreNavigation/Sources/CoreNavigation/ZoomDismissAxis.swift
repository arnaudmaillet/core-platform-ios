import CoreGraphics

/// The axis a grab-to-dismiss travels along. Historically there was exactly
/// one — horizontal, because the feed owned the whole vertical axis (paging +
/// pull-to-refresh). With the feed forward-only (cluster-gallery milestone),
/// the downward direction is free, and a dismissal may be armed on either
/// axis or both: the axis selects the progress component, the drift
/// component, the span, and the velocity the release contract reads —
/// nothing else about the grab differs.
///
/// Directionality is baked in: a dismissal travels RIGHTWARD on the
/// horizontal axis and DOWNWARD on the vertical one. There is no leftward or
/// upward dismissal anywhere in the app, so the enum does not model one.
public enum ZoomDismissAxis: Hashable, CaseIterable, Sendable {
    case horizontal
    case vertical

    /// The begin gate, shared by every armed axis: the hand's velocity must
    /// be outbound (rightward / downward) and predominantly along exactly one
    /// enabled axis. A diagonal that favors neither, an inbound movement, or
    /// a movement along a disarmed axis matches nothing — which is what lets
    /// the pager keep upward drags and the (forward-only) pager's decline
    /// hand downward ones here with no gesture-graph edges: each side of the
    /// split tests the mirror of the other's rule.
    public static func match(
        velocity: CGPoint, axes: Set<ZoomDismissAxis>
    ) -> ZoomDismissAxis? {
        if axes.contains(.horizontal), velocity.x > 0, abs(velocity.x) > abs(velocity.y) {
            return .horizontal
        }
        if axes.contains(.vertical), velocity.y > 0, abs(velocity.y) > abs(velocity.x) {
            return .vertical
        }
        return nil
    }

    /// The component of `point` along the dismissal's travel direction.
    public func along(_ point: CGPoint) -> CGFloat {
        self == .horizontal ? point.x : point.y
    }

    /// The component of `point` across the travel direction — the drift axis.
    public func across(_ point: CGPoint) -> CGFloat {
        self == .horizontal ? point.y : point.x
    }

    /// The view span progress is measured against: width for a horizontal
    /// grab, height for a vertical one, so the release contract's 0.35
    /// threshold means the same fraction of travel either way.
    public func span(of size: CGSize) -> CGFloat {
        self == .horizontal ? size.width : size.height
    }

    /// Recomposes banded along/across displacements into an (x, y) offset.
    public func offset(along: CGFloat, across: CGFloat) -> CGPoint {
        self == .horizontal
            ? CGPoint(x: along, y: across)
            : CGPoint(x: across, y: along)
    }
}
