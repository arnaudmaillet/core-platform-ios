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
/// of the gesture; this view owns the decision (the shared
/// `PullRefreshTrigger`, #2235) and the animation.
///
/// **Two states, deliberately, and no third.** Below the threshold the branded
/// loader (`AppLoaderView`, #1329) follows the finger frame for frame — the
/// icon's pieces appear, then the mark starts to turn and to thin (#1744) —
/// so the gesture feels connected. At the threshold it is half a turn into
/// its spin. Nothing snaps, and there is no "release to refresh" text — the
/// mark taking shape IS the message. At the threshold, under the finger, it
/// fires (`onRefresh`) and turns on from where the pull left it, thinning
/// into the ring; done, it fades where it is.
///
/// ⚠️ **IT FIRES DURING THE DRAG, NOT ON THE RELEASE (#2235).** A release past
/// 120 pt fired here while the plain lists fired at UIKit's own distance,
/// mid-drag, and the owner felt the profile fire "as soon as I slide down
/// from the top" next to Messages. One rule now (`PullRefreshRule`): the ring
/// full, the tick and the refresh are one moment, on every screen.
///
/// ⚠️ **ON THE PLACE PAGE THE STOCK CONTROL WAS WORSE THAN MISPLACED.** Its
/// lists kept a `UIRefreshControl` under the same floating header, and a real
/// drag in the simulator stretched the banner without ever tripping it, while
/// the same drag tripped For You's; a release through the control's own path
/// started a spinner nothing ever stopped (no host answered it). One
/// indicator, one threshold, for every page that floats a header.
public final class HeroPullToRefreshView: UIView {
    /// The app's one pull distance, `PullRefreshRule.threshold` (#2235) —
    /// read here too by the pull to close and the pull to go back.
    public static let threshold: CGFloat = PullRefreshRule.threshold

    /// A finger's pull reached the threshold (`PullRefreshRule`): the
    /// indicator is turning, the host refreshes, then calls `endRefreshing()`.
    public var onRefresh: (() -> Void)?

    private let loader = AppLoaderView(size: .medium)
    private var isRefreshing = false
    /// The shared decision, and the tick it sounds as it fires (#1354).
    private let trigger = PullRefreshTrigger()
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
    /// `isTracking` says a finger is on the list: only then can reaching the
    /// threshold tick (#1354) and refresh (#2235) — a fling, a bounce-back or
    /// a fold-back drifting past it says nothing.
    public func setPull(_ distance: CGFloat, isTracking: Bool = false) {
        #if DEBUG
        trace.follow(pulled: distance, isTracking: isTracking, threshold: Self.threshold, scrollView: tracedScrollView)
        #endif
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
        loader.setProgress(PullRefreshRule.progress(pulled: distance))
        guard trigger.update(pulled: distance, isTracking: isTracking, isRefreshing: isRefreshing) else { return }
        #if DEBUG
        trace.mark(.tick, pulled: distance, isTracking: isTracking, scrollView: tracedScrollView)
        trace.mark(.trigger, pulled: distance, isTracking: isTracking, scrollView: tracedScrollView, note: " by=rule")
        #endif
        beginRefreshing()
        onRefresh?()
    }

    public func beginRefreshing() {
        guard !isRefreshing else { return }
        isRefreshing = true
        generation += 1
        startedAt = CACurrentMediaTime()
        // From the frame the pull reached: no jump on release.
        loader.startAnimating()
    }

    /// How long the loader turns at least once a refresh starts
    /// (`PullRefreshTiming`). Tests set 0.
    public var minimumShown = PullRefreshTiming.minimumShown
    private var startedAt: CFTimeInterval?
    private var generation = 0

    #if DEBUG
    public var debugIsRefreshing: Bool { isRefreshing }
    /// The list being pulled, for the trace's finger travel
    /// (`-pull-refresh-trace`, #2235). The host names it.
    public weak var tracedScrollView: UIScrollView?
    private lazy var trace = PullRefreshTrace(view: self)
    #endif

    /// Ends the spin. Idempotent — a host stops it wherever a load settles,
    /// refreshed or not, so this is called far more often than it acts.
    public func endRefreshing() {
        guard isRefreshing else { return }
        // Not before it has turned `minimumShown` (#1901).
        if let startedAt {
            let left = minimumShown - (CACurrentMediaTime() - startedAt)
            if left > 0 {
                let asked = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + left) { [weak self] in
                    guard let self, self.generation == asked else { return }
                    self.endRefreshing()
                }
                return
            }
        }
        startedAt = nil
        isRefreshing = false
        isSettling = true
        // The mark fades where it is.
        loader.stopAnimating()
    }

    #if DEBUG
    /// The loader this indicator drives — what a test reads.
    var debugLoader: AppLoaderView { loader }
    var debugThresholdFeedback: PullThresholdFeedback { trigger.feedback }
    #endif
}
