import UIKit

/// The pull to refresh's one rule, for every screen (#2235).
///
/// Before it, two mechanisms disagreed: the plain lists (Messages,
/// Notifications, For You, …) fired at UIKit's own `UIRefreshControl`
/// distance, which moves with a list's insets, while the profile and the
/// place fired on a release past 120 pt. The ring filled and the tick
/// sounded at 120 pt on both, so the ring, the tick and the refresh said
/// different things from one screen to the next, and the owner felt the
/// profile and For You fire "as soon as I slide down from the top"
/// (2026-11-10), Messages only once the pull had gone far.
///
/// Now:
/// - **one distance**, `threshold`: the ring is full, the tick sounds and the
///   refresh fires there, together, on every screen;
/// - **one measure**: the content's overscroll past the list's top
///   (`pulled(contentOffsetY:topInset:)`), whatever the insets and the
///   floating headers — so a screen's insets cannot change it;
/// - **one moment**: during the drag, as the pull reaches the threshold —
///   iOS's own feel, Messages', and the only one UIKit's control can keep
///   (it holds the list open from the moment it fires);
/// - **a finger's pull only**: a fling or a bounce that reaches the top never
///   refreshes, nor does a pull let go short of the threshold.
public enum PullRefreshRule {
    /// How far past its top a list is pulled, in content points, before the
    /// refresh fires. The ring fills over it and the tick sounds at it.
    ///
    /// ⚠️ TO BE MEASURED (#2235): it is to be Messages' trigger, read with
    /// `-pull-refresh-trace` on a device. Until then, the distance the ring
    /// and the tick already used everywhere. Also the pull to close's and the
    /// pull to go back's distance (`HeroPullToRefreshView.threshold`): the
    /// app's one pull distance.
    public static let threshold: CGFloat = 120

    /// The overscroll past the list's top: what `threshold` is expressed in.
    /// `topInset` is the list's top inset AT REST — its adjusted inset, the
    /// header a hosted page floats under included, and never a refresh's own
    /// hold (UIKit adds it to the adjusted inset while it refreshes).
    public static func pulled(contentOffsetY: CGFloat, topInset: CGFloat) -> CGFloat {
        -(contentOffsetY + topInset)
    }

    /// Whether this reading of a pull refreshes: the one decision both
    /// mechanisms take (`PullRefreshTrigger`).
    ///
    /// - `pulled`: the overscroll, `pulled(contentOffsetY:topInset:)`;
    /// - `isTracking`: a finger is on the list — a fling, a bounce or a
    ///   fold-back never refreshes;
    /// - `isRefreshing`: a refresh already runs — one at a time;
    /// - `wasShortUnderFinger`: this drag read the pull short of the
    ///   threshold at least once. A finger catching a bounce already past the
    ///   threshold did not pull it there, so it does not refresh.
    public static func shouldRefresh(
        pulled: CGFloat, isTracking: Bool, isRefreshing: Bool, wasShortUnderFinger: Bool
    ) -> Bool {
        isTracking && !isRefreshing && wasShortUnderFinger && pulled >= threshold
    }

    /// The ring's fill for a pull: full exactly where the refresh fires.
    public static func progress(pulled: CGFloat) -> CGFloat {
        min(max(pulled / threshold, 0), 1)
    }
}

/// One pull, read frame by frame: the shared decision
/// (`PullRefreshRule.shouldRefresh`) with what it remembers of the drag, and
/// the tick (`PullThresholdFeedback`, #1354), which sounds on the frame the
/// refresh fires and on no other (#2235). Both indicators wear one:
/// `AppRefreshControl` and `HeroPullToRefreshView`.
@MainActor
public final class PullRefreshTrigger {
    /// The tick.
    public let feedback = PullThresholdFeedback()
    /// This drag has read the pull short of the threshold under the finger.
    public private(set) var wasShortUnderFinger = false

    public init() {}

    /// Re-reads the pull. Returns whether it fires now — the tick has sounded
    /// then, and the caller starts the refresh.
    @discardableResult
    public func update(pulled: CGFloat, isTracking: Bool, isRefreshing: Bool) -> Bool {
        guard isTracking else {
            // The finger lifted: whatever the list does now is not a pull.
            wasShortUnderFinger = false
            feedback.update(pulled: pulled, threshold: PullRefreshRule.threshold, isTracking: false)
            return false
        }
        if pulled < PullRefreshRule.threshold { wasShortUnderFinger = true }
        let fires = PullRefreshRule.shouldRefresh(
            pulled: pulled, isTracking: isTracking, isRefreshing: isRefreshing,
            wasShortUnderFinger: wasShortUnderFinger
        )
        if pulled > 0, !isRefreshing, !feedback.isArmed { feedback.prepare() }
        // The tick hears the pull only when it fires — a caught bounce, or a
        // refresh already running, crosses the line silently.
        let tickable: Bool = fires
        feedback.update(pulled: pulled, threshold: PullRefreshRule.threshold, isTracking: tickable)
        // A refresh fired: a new one needs the pull short again first.
        if fires { wasShortUnderFinger = false }
        return fires
    }
}
