import UIKit

/// A `UIRefreshControl` that draws the branded loader (#1329) instead of the
/// stock spinner, and fires at the app's one pull distance (#2235):
/// `scrollView.refreshControl =`, `onRefresh`, `endRefreshing()`,
/// `isRefreshing`.
///
/// UIKit keeps what it does well — the gesture, the inset that holds the list
/// open while refreshing, the fold-back. The drawing is the app's: the stock
/// spinner is tinted away and the loader follows the pull (`setProgress`),
/// turns on from there when the control fires, and closes when it ends.
///
/// ## The trigger is the app's (#2235)
///
/// UIKit's own distance moves with the list's insets — For You, under its
/// header, fired sooner than Messages for the same drag — and the ring and
/// the tick filled over the app's 120 pt whatever UIKit did. So this control
/// takes the decision: `PullRefreshTrigger` reads the overscroll past the
/// list's resting top, and when the shared rule says so — the ring full, the
/// tick, under a finger — it begins refreshing itself and calls `onRefresh`.
///
/// UIKit's own trigger cannot be switched off. When it fires FIRST, it has
/// only put the list in its refreshing state: the host is not told, the
/// loader keeps following the finger, and either the pull reaches the
/// threshold under the finger (the refresh is the app's from there) or the
/// finger lets go short and UIKit's refresh is ended at once — the list
/// folds back as from any short pull. That is why hosts listen to
/// `onRefresh`, never to `.valueChanged`, which UIKit sends at its own
/// distance.
///
/// ⚠️ Lists under a floating header (the profile, the place) keep
/// `HeroPullToRefreshView`: a refresh control there draws under the header,
/// mid-screen — see that type. Both wear the same `PullRefreshTrigger`.
public final class AppRefreshControl: UIRefreshControl {
    /// A finger's pull reached the threshold (`PullRefreshRule`): the control
    /// is refreshing and the loader turning. The host loads, then calls
    /// `endRefreshing()`. A programmatic `beginRefreshing()` does not call it.
    public var onRefresh: (() -> Void)?

    private let loader = AppLoaderView(size: .medium)
    private var offsetObservation: NSKeyValueObservation?
    /// The shared decision, and the tick it sounds as it fires (#1354).
    private let trigger = PullRefreshTrigger()
    /// The list's top inset at rest: UIKit adds its hold to the adjusted
    /// inset while it refreshes, which must not shorten the measure.
    private var restingTopInset: CGFloat = 0
    /// UIKit's own trigger fired before the shared rule did: the list is in
    /// UIKit's refreshing state, nobody has been told, and the pull decides.
    private var isNativeRefreshPending = false
    /// The control is beginning a refresh itself: UIKit's callbacks and offset
    /// writes during it are neither UIKit's trigger nor a pull.
    private var isBeginningForTheRule = false
    /// A refresh just ended and the list is folding back (#1400).
    private var isSettling = false
    /// How long the loader turns at least once a refresh starts
    /// (`PullRefreshTiming`). Tests set 0.
    public var minimumShown = PullRefreshTiming.minimumShown
    /// When the current refresh started, and which one it is: a delayed end
    /// never ends a refresh that started after it was asked.
    private var startedAt: CFTimeInterval?
    private var generation = 0

    public override init() {
        super.init()
        // The stock spinner and its pull arrow, tinted away; the loader draws.
        tintColor = .clear
        addSubview(loader)
        // UIKit's own trigger, at UIKit's distance: held until the pull says
        // (see the type's note).
        addAction(UIAction { [weak self] _ in self?.nativeTriggerFired() }, for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        loader.center = CGPoint(x: bounds.midX, y: bounds.midY)
        bringSubviewToFront(loader)
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        let scrollView = superview as? UIScrollView
        restingTopInset = scrollView?.adjustedContentInset.top ?? 0
        offsetObservation = scrollView?.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.follow(scrollView) }
        }
    }

    /// The pull, as far past the list's resting top as the shared rule reads.
    private func follow(_ scrollView: UIScrollView) {
        follow(scrollView, isTracking: scrollView.isTracking)
    }

    private func follow(_ scrollView: UIScrollView, isTracking: Bool) {
        // UIKit moving the list as the control begins is not a reading.
        guard !isBeginningForTheRule else { return }
        // Not while UIKit holds the list open: its hold is not the list's top.
        if !isRefreshing { restingTopInset = scrollView.adjustedContentInset.top }
        let pulled = PullRefreshRule.pulled(contentOffsetY: scrollView.contentOffset.y, topInset: restingTopInset)
        #if DEBUG
        trace.follow(
            pulled: pulled, isTracking: isTracking, threshold: PullRefreshRule.threshold, scrollView: scrollView
        )
        #endif
        follow(pulled: pulled, isTracking: isTracking)
    }

    /// One reading of the pull: the ring, the tick and the trigger.
    private func follow(pulled: CGFloat, isTracking: Bool) {
        guard !isRefreshing || isNativeRefreshPending else { return }
        // ⚠️ THE FOLD-BACK IS NOT A PULL (#1400): once the ring's fade ended,
        // the loader took the inset still closing for a pull and drew its
        // first pills for a frame or two. It follows again from rest, or
        // from a new drag.
        if isSettling {
            guard pulled <= 0 || isTracking else { return }
            isSettling = false
        }
        loader.setProgress(PullRefreshRule.progress(pulled: pulled))
        // UIKit's held refresh is not a refresh yet: the pull still decides.
        let isRefreshUnderWay: Bool = isRefreshing && !isNativeRefreshPending
        let fires = trigger.update(pulled: pulled, isTracking: isTracking, isRefreshing: isRefreshUnderWay)
        if fires {
            refreshForTheRule()
        } else if isNativeRefreshPending, !isTracking {
            // UIKit fired at its own distance and the finger let go short of
            // the app's: no refresh. The list folds back as from a short pull.
            cancelNativeRefresh()
        }
    }

    /// The shared rule fired: the refresh starts here, under the finger.
    private func refreshForTheRule() {
        #if DEBUG
        traceMoment(.tick)
        traceMoment(.trigger, note: isNativeRefreshPending ? " by=rule (native held)" : " by=rule")
        #endif
        if !isRefreshing {
            isBeginningForTheRule = true
            super.beginRefreshing()
            isBeginningForTheRule = false
        }
        isNativeRefreshPending = false
        started()
        loader.startAnimating()
        onRefresh?()
    }

    /// UIKit's own trigger sent `.valueChanged`. Its refresh is held: the host
    /// hears of a refresh only from the shared rule.
    private func nativeTriggerFired() {
        // Only UIKit's own trigger: it enters its refreshing state, then says.
        guard !isBeginningForTheRule, startedAt == nil, isRefreshing else { return }
        #if DEBUG
        traceMoment(.trigger, note: " by=native (held)")
        #endif
        isNativeRefreshPending = true
    }

    /// The loader never turned: it keeps following the list as it folds back,
    /// as after any short pull — no fold-back hold (#1400) to apply.
    private func cancelNativeRefresh() {
        isNativeRefreshPending = false
        // ⚠️ Never UIKit's end with no refresh under way (#2097).
        guard isRefreshing else { return }
        #if DEBUG
        debugEndsPassedToUIKit += 1
        #endif
        super.endRefreshing()
    }

    public override func beginRefreshing() {
        isBeginningForTheRule = true
        super.beginRefreshing()
        isBeginningForTheRule = false
        isNativeRefreshPending = false
        started()
        loader.startAnimating()
    }

    /// Ends the spin, once it has turned `minimumShown`: a list that answers
    /// from memory would otherwise flash the loader for a frame (#1901, the
    /// owner 2026-10-30, next to the Feed's, which waits on the network).
    ///
    /// ⚠️ NOT REFRESHING, NOTHING TO END (#2097). UIKit's `endRefreshing`
    /// puts the list's offset back even when no refresh is under way
    /// (`_endRefreshingAnimated:` → `setContentOffset`), and that write STOPS
    /// A DECELERATION DEAD (`_stopScrollDecelerationNotify:`). Hosts end their
    /// controls whenever a load settles — For You after every page — so a fast
    /// fling stopped at each page landing, measured at 5,000 pt/s.
    public override func endRefreshing() {
        guard isRefreshing else {
            startedAt = nil
            loader.stopAnimating()
            return
        }
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
        isSettling = true
        isNativeRefreshPending = false
        #if DEBUG
        debugEndsPassedToUIKit += 1
        #endif
        super.endRefreshing()
        loader.stopAnimating()
    }

    private func started() {
        generation += 1
        startedAt = CACurrentMediaTime()
    }

    #if DEBUG
    /// `-pull-refresh-trace` (#2235).
    private lazy var trace = PullRefreshTrace(view: self)

    private func traceMoment(_ moment: PullRefreshTrace.Moment, note: String = "") {
        guard PullRefreshTrace.isEnabled, let scrollView = superview as? UIScrollView else { return }
        let pulled = PullRefreshRule.pulled(contentOffsetY: scrollView.contentOffset.y, topInset: restingTopInset)
        trace.mark(moment, pulled: pulled, isTracking: scrollView.isTracking, scrollView: scrollView, note: note)
    }

    /// The loader this control drives — what a test reads.
    var debugLoader: AppLoaderView { loader }
    var debugThresholdFeedback: PullThresholdFeedback { trigger.feedback }
    /// UIKit's own trigger fired and the pull has not decided yet (#2235).
    public var debugIsNativeRefreshPending: Bool { isNativeRefreshPending }
    /// The ends handed to UIKit's own — whose offset write stops a list's
    /// deceleration (#2097). Tests.
    public private(set) var debugEndsPassedToUIKit = 0
    /// Drives the pull as an offset would (#1400). Tests.
    func debugFollow(_ scrollView: UIScrollView) { follow(scrollView) }
    /// Drives the pull as an offset would, a finger on the list or not — a
    /// test cannot put one there (`isTracking` is UIKit's) (#2235).
    public func debugFollow(_ scrollView: UIScrollView, isTracking: Bool) {
        follow(scrollView, isTracking: isTracking)
    }
    /// A reading of the pull, `pulled` past the list's top (#2235). Tests.
    public func debugFollow(pulled: CGFloat, isTracking: Bool) { follow(pulled: pulled, isTracking: isTracking) }
    /// A finger pulls the list from its top to `distance` past it and lets
    /// go, through the shared rule — what a host's test drives (#2235).
    public func debugFingerPull(to distance: CGFloat) {
        follow(pulled: 0, isTracking: true)
        follow(pulled: distance, isTracking: true)
        follow(pulled: distance, isTracking: false)
    }
    /// UIKit's own trigger, as it fires at its distance (#2235). Tests.
    public func debugNativeTrigger() {
        isBeginningForTheRule = true
        super.beginRefreshing()
        isBeginningForTheRule = false
        nativeTriggerFired()
    }
    #endif
}

/// The pull to refresh's timing, one for every list (#1901).
public enum PullRefreshTiming {
    /// How long the loader turns at least, however fast the list answers:
    /// the inbox reloading from memory flashed it for a frame.
    public static let minimumShown: TimeInterval = 1.0
}
