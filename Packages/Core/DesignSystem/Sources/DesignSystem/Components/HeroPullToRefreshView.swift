import UIKit

/// The pull-to-refresh indicator of the picture-led pages — the profile and
/// the place — hosted at the very top of the screen: above the header, not
/// inside the list.
///
/// ## Why this is not a `UIRefreshControl`
///
/// A `UIRefreshControl` positions itself against its scroll view's content
/// top. These pages' lists are inset below a floating header, so the stock
/// control drew its spinner *under the identity block*, mid-screen, pointing at
/// the grid rather than at the page being refreshed. There is no outer scroll
/// view to move it to: the header is a floating passthrough layer over a pager,
/// not a subview of anything that scrolls.
///
/// So the pull is read from the list — which already reports its overscroll —
/// and rendered here, pinned to the top of the screen. The list keeps ownership
/// of the gesture; this view owns only the threshold and the animation.
///
/// **Two states, deliberately, and no third.** Below the threshold the branded
/// loader (`AppLoaderView`, #1329) follows the finger frame for frame — the
/// icon's pieces appear, then the mark starts to turn and to thin (#1744) —
/// so the gesture feels connected. At the threshold it is half a turn into
/// its spin. Nothing snaps, and there is no "release to refresh" text — the
/// mark taking shape IS the message. Released past it, it turns on from where
/// the pull left it, thinning into the ring; done, it fades where it is.
///
/// ⚠️ **ON THE PLACE PAGE THE STOCK CONTROL WAS WORSE THAN MISPLACED.** Its
/// lists kept a `UIRefreshControl` under the same floating header, and a real
/// drag in the simulator stretched the banner without ever tripping it, while
/// the same drag tripped For You's; a release through the control's own path
/// started a spinner nothing ever stopped (no host answered it). One
/// indicator, one threshold, for every page that floats a header.
public final class HeroPullToRefreshView: UIView {
    /// How far the list must be pulled past its top before releasing refreshes.
    ///
    /// Matches the distance `UIRefreshControl` uses, so the gesture costs the
    /// same effort here as everywhere else in the app.
    public static let threshold: CGFloat = 120

    private let loader = AppLoaderView(size: .medium)
    private var isRefreshing = false
    /// The tick as the pull crosses the threshold (#1354).
    private let thresholdFeedback = PullThresholdFeedback()
    /// A refresh just ended and the list is folding back (#1400).
    private var isSettling = false

    override public init(frame: CGRect) {
        super.init(frame: frame)
        // Nothing to hit: the list underneath owns every touch in this band.
        isUserInteractionEnabled = false
        // ⚠️ Above the header, which is added to the same parent AFTER this and
        // whose banner is opaque across the whole top of the screen. Ordering
        // by `bringSubviewToFront` at setup time does not survive that, and the
        // spinner rendered behind the banner — invisible, while every value
        // driving it was correct. `zPosition` is what the retired
        // `UIRefreshControl` used here for the same reason.
        layer.zPosition = 10
        loader.constrain(in: self) { parent in
            loader.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            loader.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Tracks an in-progress pull. `distance` is how far the list is past its
    /// top, in points.
    ///
    /// `isTracking` says a finger is on the list: only then does crossing the
    /// threshold tick (#1354) — a bounce-back drifting past it says nothing.
    public func setPull(_ distance: CGFloat, isTracking: Bool = false) {
        guard !isRefreshing else { return }
        // ⚠️ THE FOLD-BACK IS NOT A PULL (#1400): once the ring's fade ended,
        // the loader took the list still closing for a pull and drew its
        // first pills for a frame or two. It follows again from rest, or
        // from a new drag.
        if isSettling {
            guard distance <= 0 || isTracking else { return }
            isSettling = false
        }
        // The mark is drawn out by the pull, rather than waiting to appear.
        loader.setProgress(min(max(distance / Self.threshold, 0), 1))
        if distance > 0, isTracking, !thresholdFeedback.isArmed { thresholdFeedback.prepare() }
        thresholdFeedback.update(pulled: distance, threshold: Self.threshold, isTracking: isTracking)
    }

    /// Whether a release at `distance` should refresh.
    public func shouldRefresh(releasedAt distance: CGFloat) -> Bool {
        !isRefreshing && distance >= Self.threshold
    }

    public func beginRefreshing() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // From the frame the pull reached: no jump on release.
        loader.startAnimating()
    }

    #if DEBUG
    public var debugIsRefreshing: Bool { isRefreshing }
    #endif

    /// Ends the spin. Idempotent — a host stops it wherever a load settles,
    /// refreshed or not, so this is called far more often than it acts.
    public func endRefreshing() {
        guard isRefreshing else { return }
        isRefreshing = false
        isSettling = true
        // The mark fades where it is.
        loader.stopAnimating()
    }

    #if DEBUG
    /// The loader this indicator drives — what a test reads.
    var debugLoader: AppLoaderView { loader }
    var debugThresholdFeedback: PullThresholdFeedback { thresholdFeedback }
    #endif
}
