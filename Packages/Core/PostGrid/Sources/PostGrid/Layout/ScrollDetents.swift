import CoreGraphics

/// Where a release comes to rest on a page hosted under a floating header: a
/// few positions the finger's release is drawn to, rather than anywhere in
/// between. Shared by every host that sets detents on its pages — the
/// profile's (`ProfileScrollDetents` names its positions) — through
/// `ForYouGridPage` (#1273).
///
/// Past the last detent the offset belongs to the list and is left alone.
public enum ScrollDetents {
    /// Where a release aimed at `target` should stop instead, or nil where
    /// the offset is the list's own: above the top (a pull) or past the last
    /// detent.
    ///
    /// The NEAREST detent to where the scroll would have stopped, not the
    /// next one in the direction of travel: the target already carries the
    /// fling's momentum, so a short flick that would have stopped just past
    /// a detent lands on it, and a long one that would have cleared the next
    /// lands there.
    public static func snapped(
        target: CGFloat, detents: [CGFloat], from: CGFloat? = nil, catching: [CGFloat] = []
    ) -> CGFloat? {
        guard let last = detents.last, target >= 0, target <= last + beyondSlack else { return nil }
        // A CATCHING detent stops a release that crosses it, however hard it
        // was flung (a band card's avatar under the bar — a notch, the owner,
        // 2026-10-15): the first one met in the direction of travel.
        if let from {
            let crossed = catching
                .filter { (from < $0 && target > $0) || (from > $0 && target < $0) }
                .sorted { abs($0 - from) < abs($1 - from) }
            if let stop = crossed.first { return stop }
        }
        if target >= last { return last }
        return detents.min { abs($0 - target) < abs($1 - target) }
    }

    /// How far past the last detent a release may be heading and still be
    /// drawn back onto it. A flick from the top that would have run a little
    /// into the list stops at the first post instead — that is what the
    /// detent is for — while a flick that clears it by more is a scroll of
    /// the list and is left alone.
    public static let beyondSlack: CGFloat = 100
}
