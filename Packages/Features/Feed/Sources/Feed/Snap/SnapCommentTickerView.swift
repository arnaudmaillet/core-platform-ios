import UIKit

/// The danmaku band: `laneCount` lanes of naked micro-reaction text conveying
/// right-to-left over the page's media, directly above the caption. Text
/// carries no capsule — legibility comes from the chrome's bottom scrim,
/// which extends behind the whole band.
///
/// # The conveyor
/// Steady state is pure Core Animation. Each bubble's flight is one linear
/// `CABasicAnimation` on `position.x`, executed entirely on the render
/// server: the main thread is touched only at spawn/retire, so the stream
/// stays fluid at the display's native rate over playing video and is immune
/// to main-thread hitches. Each lane runs at its own constant speed
/// (staggered across lanes, never within one) and spawns its next bubble
/// only once the previous one has fully entered plus a gap. Activation
/// pre-fills every lane mid-stream, so the band lands populated; the first
/// fresh spawn continues the fill's cadence seamlessly.
///
/// # The scrub
/// The band is directly manipulable: a horizontal pan freezes the conveyor
/// (presentation positions written into the model layers — the standard
/// interruptible-animation takeover), tracks the finger 1:1, and backfills
/// both edges from the wrap-around queue so the user can scrub forward and
/// backward without holes. Release relaxes each lane's velocity
/// exponentially from the finger's release velocity to the lane's steady
/// drift (`v(t) = -vₖ + (V₀+vₖ)·e^(-t/τ)`), integrated by a `CADisplayLink`
/// that lives only for the interaction transient; when the residual is
/// imperceptible the bubbles are handed back to CA at exactly matched
/// velocity. A kinetic blur (`systemThickMaterial`) behind the band tracks
/// the touch's ACCUMULATED absolute travel — monotone non-decreasing while
/// the finger is down, so a hold freezes at its peak — via a paused
/// `UIViewPropertyAnimator`'s `fractionComplete`; release relaxes it on the
/// coast's exponential clock, and at steady state the surface is hidden
/// (zero cost).
///
/// # Lifecycle
/// Hard stop/start, not a freeze: deactivation retires everything in flight,
/// which keeps backgrounding safe (the system strips CA animations from
/// backgrounded apps) and cell reuse leak-proof. Every deactivation path
/// also takes the band off screen, so nothing is ever seen stopping.
final class SnapCommentTickerView: UIView {
    static let laneCount = 2
    /// Per-lane speeds (pt/s). Deliberately staggered and incommensurate so
    /// the lanes drift out of phase instead of moving as a block.
    /// Calibrated low: the band is a micro-reaction dump and should glide
    /// calmly under the media, not race across it.
    static let laneSpeeds: [CGFloat] = [22, 26]
    /// Per-lane phase, in seconds of travel. The pre-fill shifts each lane's
    /// bubble train left by `phase × speed` points — as if that lane had
    /// entered the loop this much earlier — so the lanes land visibly out of
    /// step instead of column-aligned at the left edge. (Sized for up to
    /// three lanes; only the first `laneCount` entries are read.)
    static let lanePhases: [TimeInterval] = [0.3, 1.5, 2.7]
    /// Minimum horizontal daylight between two bubbles in the same lane —
    /// generous, so the slow glide reads sparse rather than congested.
    static let interItemGap: CGFloat = 16
    private static let laneSpacing: CGFloat = 3

    // MARK: Interaction tuning

    /// Exponential time constant for the release decay back to steady drift.
    static let decayTimeConstant: TimeInterval = 0.35
    /// Residual manual velocity (pt/s) under which the conveyor resumes CA —
    /// below perception, so the handover cannot be seen.
    static let restVelocityTolerance: CGFloat = 2
    /// The blur animator's fraction ceiling: enough depth-of-field to read
    /// as kinetic, not enough to obliterate the reactions being scrubbed.
    static let maxBlurFraction: CGFloat = 0.65
    /// The backdrop never disappears under a live touch: engagement starts
    /// here at touch-down, and the accumulator can only raise it.
    static let scrubEngagementFloor: CGFloat = 0.25
    /// Accumulated absolute travel (pt) at which the backdrop reaches its
    /// cap.
    static let blurDistanceScale: CGFloat = 260

    /// Accumulated |Δx| → backdrop fraction while the finger is down. A true
    /// accumulator: monotone non-decreasing over the touch lifecycle — it
    /// starts at the engagement floor, builds with absolute travel, and
    /// FREEZES at its peak when the thumb slows or stops. Instantaneous
    /// velocity plays no part until the gesture ends.
    static func scrubFraction(forAccumulatedDistance distance: CGFloat) -> CGFloat {
        scrubEngagementFloor
            + (maxBlurFraction - scrubEngagementFloor) * min(1, distance / blurDistanceScale)
    }
    /// How far past either edge a scrubbed bubble may sit before retiring.
    private static let scrubMargin: CGFloat = 48

    /// One in-flight reaction and where its text lives in the lane's queue —
    /// the index is what makes bidirectional backfill well-defined. A class:
    /// flight bookkeeping mutates as ownership moves between CA and touch.
    private final class Bubble {
        let label: TickerBubbleLabel
        let width: CGFloat
        let itemIndex: Int
        /// Where and when the current CA flight departed — the analytic
        /// freeze fallback for a flight grabbed before its first frame was
        /// committed (`presentation()` is nil until then).
        var flightStartX: CGFloat = 0
        var flightStartTime: CFTimeInterval = 0

        init(label: TickerBubbleLabel, width: CGFloat, itemIndex: Int) {
            self.label = label
            self.width = width
            self.itemIndex = itemIndex
        }
    }

    /// `conveying` = render-server CA flights; `scrubbing` = finger owns the
    /// positions; `coasting` = display-link decay back toward `conveying`.
    private enum Mode {
        case parked
        case conveying
        case scrubbing
        case coasting
    }

    private let bubbleHeight: CGFloat
    private var queue: [TickerCommentModel] = []
    /// The queue dealt round-robin into one sub-queue per lane: scrubbing
    /// backward needs "the previous item of THIS lane", which only exists if
    /// lane membership is a property of the item, not of spawn timing.
    private var laneQueues: [[TickerCommentModel]] = Array(repeating: [], count: SnapCommentTickerView.laneCount)
    /// Per lane: the sub-queue index the next right-edge spawn will show.
    private var laneNextIndex: [Int] = Array(repeating: 0, count: SnapCommentTickerView.laneCount)
    /// Per lane, ordered left → right.
    private var laneBubbles: [[Bubble]] = Array(repeating: [], count: SnapCommentTickerView.laneCount)
    /// Mirrors the owning cell's visibility; content may arrive before or
    /// after it, so both paths funnel into `startIfNeeded`.
    private var isActive = false
    private var mode: Mode = .parked
    /// Invalidates in-flight CA completion blocks across a stop or a scrub
    /// takeover: completions fire even for removed animations, and a stale
    /// one must not touch a bubble a newer owner already controls.
    private var generation = 0
    private var spawnTimers: [Timer?] = Array(repeating: nil, count: SnapCommentTickerView.laneCount)
    private var pool: [TickerBubbleLabel] = []
    /// Measures widths without touching the pool — pre-fill and backfill must
    /// know a bubble's width before deciding whether it is even on screen.
    private let measuringBubble = TickerBubbleLabel()

    // MARK: Interaction state

    private let panRecognizer = UIPanGestureRecognizer()
    private var coastLink: CADisplayLink?
    private var coastReleaseVelocity: CGFloat = 0
    /// The backdrop value held at release — the coast's fade envelope starts
    /// here, so lifting the finger never discontinues the feedback.
    private var coastReleaseFraction: CGFloat = 0
    private var coastStart: CFTimeInterval = 0
    private var coastLastTimestamp: CFTimeInterval = 0
    private var lastPanTranslation: CGFloat = 0
    /// The accumulator: total absolute travel of the current touch. Only
    /// ever grows while scrubbing; reset by the next `beginScrub`.
    private var scrubAccumulatedDistance: CGFloat = 0
    /// The kinetic depth-of-field surface behind the band — hidden (zero
    /// render cost) except during manual interaction.
    private let blurView = UIVisualEffectView(effect: nil)
    /// Paused animator whose `fractionComplete` IS the blur intensity — the
    /// standard variable-blur technique. `pauseAnimation()` is mandatory: an
    /// `.inactive` animator silently ignores `fractionComplete` (the
    /// invisible-blur field bug).
    private var blurAnimator: UIViewPropertyAnimator?
    /// A released surface's reversal run, kept separate so a re-grab can
    /// stop it and take the surface back over.
    private var blurDismissAnimator: UIViewPropertyAnimator?
    /// Settles any animator still engaged when the ticker is released —
    /// deallocating a paused/unfinished `UIViewPropertyAnimator` is a UIKit
    /// exception, and a ticker can die mid-interaction.
    private let animatorBag = KineticAnimatorBag()

    override init(frame: CGRect) {
        bubbleHeight = ceil(UIFont.preferredFont(forTextStyle: .caption1).lineHeight)
            + TickerBubbleLabel.textInsets.top + TickerBubbleLabel.textInsets.bottom
        super.init(frame: frame)
        isHidden = true
        // CLIPPED at the band's own edges: the trailing edge is no longer
        // the screen's (it sits at the shortcut rail's glass square, mid
        // screen), and bubbles spawn just past it — clipping is what makes
        // them materialize UNDER the frosted square and slide out of its
        // seam instead of popping in over bare media. (A rightward scrub
        // sends them back INTO the square the same way.)
        clipsToBounds = true

        blurView.isHidden = true
        blurView.isUserInteractionEnabled = false
        blurView.accessibilityIdentifier = "ticker-kinetic-backdrop"
        insertSubview(blurView, at: 0)

        // Horizontal-only pan; taps still fall through to the cell's
        // playback toggle (the band is neither a UIControl nor one of the
        // chrome's interactionRoots, so the cell's arbitration ignores it).
        // The delegate declares the band's priority over other pans (the
        // timeline slide-to-pop, the pin grab) inside its own frame.
        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        panRecognizer.delegate = self
        addGestureRecognizer(panRecognizer)
    }

    /// Horizontal intent only: vertical drags stay with the page scroller.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard mode != .parked else { return false }
        let velocity = panRecognizer.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: CGFloat(Self.laneCount) * bubbleHeight + CGFloat(Self.laneCount - 1) * Self.laneSpacing
        )
    }

    // MARK: - Content & lifecycle

    /// Replaces the wrap-around queue. An empty queue (post below the
    /// engagement gate, or nothing loaded yet) hides the band entirely — the
    /// caption keeps its normal anchoring either way, since the band floats
    /// over the media and never pushes layout. Re-applying an identical queue
    /// is a no-op so cached re-deliveries don't restart a running stream.
    func setComments(_ comments: [TickerCommentModel]) {
        guard comments != queue else { return }
        let wasEmpty = queue.isEmpty
        stopStream()
        queue = comments
        for lane in 0..<Self.laneCount {
            laneQueues[lane] = comments.enumerated()
                .filter { $0.offset % Self.laneCount == lane }
                .map(\.element)
            laneNextIndex[lane] = 0
        }
        isHidden = comments.isEmpty || UIAccessibility.isReduceMotionEnabled
        startIfNeeded()
        // Data landing on a page that is ALREADY on screen (a slow network
        // beat the prefetch): ease the pre-filled train in instead of popping
        // it. Off-screen configuration (`window == nil`) skips this — the
        // band is simply there when the page scrolls in.
        if wasEmpty, !comments.isEmpty, window != nil {
            alpha = 0
            UIView.animate(withDuration: 0.3) { self.alpha = 1 }
        }
    }

    /// Visibility-scoped: any on-screen page streams — including one being
    /// dragged partway in — with the cell's activation seam doubling as the
    /// backgrounding stop / foregrounding restart edge.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        active ? startIfNeeded() : stopStream()
    }

    /// Cell reuse: drop content, activation, and every in-flight bubble — a
    /// recycled cell is never the active page until the dispatcher says so.
    func reset() {
        stopStream()
        isActive = false
        queue = []
        laneQueues = Array(repeating: [], count: Self.laneCount)
        laneNextIndex = Array(repeating: 0, count: Self.laneCount)
        isHidden = true
        alpha = 1 // a reuse mid-entrance-fade must not strand a dim band
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        // Activation can precede first layout (configure → willBecomeActive
        // before the cell is sized); spawning needs a real width.
        startIfNeeded()
    }

    // MARK: - Lane scheduling (steady conveyor)

    private func startIfNeeded() {
        guard isActive, mode == .parked, !queue.isEmpty, bounds.width > 0,
              !UIAccessibility.isReduceMotionEnabled else { return }
        mode = .conveying
        for lane in 0..<Self.laneCount {
            prefillLane(lane)
        }
    }

    private func stopStream() {
        generation += 1
        mode = .parked
        for timer in spawnTimers { timer?.invalidate() }
        spawnTimers = Array(repeating: nil, count: Self.laneCount)
        stopCoast()
        setBlurIntensity(0)
        // Cancel any in-progress grab (a page can deactivate mid-touch).
        panRecognizer.isEnabled = false
        panRecognizer.isEnabled = true
        for lane in 0..<Self.laneCount {
            for bubble in laneBubbles[lane] {
                bubble.label.layer.removeAllAnimations()
                recycle(bubble.label)
            }
            laneBubbles[lane].removeAll()
        }
    }

    private func armSpawn(lane: Int, after delay: TimeInterval) {
        let timer = Timer.scheduledTimer(withTimeInterval: max(0, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.spawn(inLane: lane) }
        }
        // Spawn timing is not frame-precise work; tolerance keeps the timer
        // cheap while video plays.
        timer.tolerance = max(0.05, delay * 0.1)
        spawnTimers[lane] = timer
    }

    /// Populates one lane the way it would look mid-stream: a left-to-right
    /// train at steady-state spacing, phase-shifted left so lanes don't
    /// align, every bubble flying at the lane's constant speed over exactly
    /// its remaining distance. The cursor's overshoot past the entry edge,
    /// at lane speed, times the first fresh spawn — the loop continues the
    /// fill's cadence without a seam.
    private func prefillLane(_ lane: Int) {
        guard !laneQueues[lane].isEmpty else { return }
        let bandWidth = bounds.width
        let speed = Self.laneSpeeds[lane]
        var cursor = -CGFloat(Self.lanePhases[lane]) * speed
        while cursor < bandWidth {
            let itemIndex = laneNextIndex[lane]
            let item = laneItem(lane, at: itemIndex)
            laneNextIndex[lane] = wrapped(itemIndex + 1, laneQueues[lane].count)
            let width = measuredBubbleWidth(for: item.text, in: bandWidth)
            // A slot wholly left of the band is a bubble that "already
            // exited": consume its queue slot but materialize nothing.
            if cursor + width > 0 {
                let bubble = materializeBubble(item, atIndex: itemIndex, lane: lane, leftEdge: cursor, width: width)
                laneBubbles[lane].append(bubble)
                animateToExit(bubble, lane: lane)
            }
            cursor += width + Self.interItemGap
        }
        armSpawn(lane: lane, after: TimeInterval((cursor - bandWidth) / speed))
    }

    /// Seconds until the entry edge is clear given the rightmost bubble's
    /// current right edge; 0 when the gap is already open. Pure — this is
    /// the no-overlap contract.
    static func entryDeferral(lastRightEdge: CGFloat, bandWidth: CGFloat, speed: CGFloat) -> TimeInterval {
        TimeInterval(max(0, (lastRightEdge + interItemGap - bandWidth) / speed))
    }

    /// The steady loop: one fresh bubble at the entry edge, then re-arm for
    /// when it has fully entered plus the gap — at constant per-lane speed
    /// that guarantees no overlap.
    private func spawn(inLane lane: Int) {
        let bandWidth = bounds.width
        guard mode == .conveying, !laneQueues[lane].isEmpty, bandWidth > 0 else { return }

        // Geometry-checked entry: never trust the timer cadence alone. A
        // percent-driven transition (swipe-to-pop, pin grab) freezes the
        // layer clock while wall-clock timers keep firing — the presentation
        // layer reports the frozen truth, so measuring the actual gap makes
        // overlap impossible by construction and simply defers the spawn
        // until the clock runs again.
        if let last = laneBubbles[lane].last {
            let lastRight = currentVisualCenterX(of: last, lane: lane) + last.width / 2
            let deferral = Self.entryDeferral(
                lastRightEdge: lastRight, bandWidth: bandWidth, speed: Self.laneSpeeds[lane]
            )
            if deferral > 0 {
                armSpawn(lane: lane, after: max(0.1, deferral))
                return
            }
        }

        let itemIndex = laneNextIndex[lane]
        let item = laneItem(lane, at: itemIndex)
        laneNextIndex[lane] = wrapped(itemIndex + 1, laneQueues[lane].count)
        let width = measuredBubbleWidth(for: item.text, in: bandWidth)
        let bubble = materializeBubble(item, atIndex: itemIndex, lane: lane, leftEdge: bandWidth, width: width)
        laneBubbles[lane].append(bubble)
        animateToExit(bubble, lane: lane)
        armSpawn(lane: lane, after: TimeInterval((width + Self.interItemGap) / Self.laneSpeeds[lane]))
    }

    /// Places a label in the lane at `leftEdge` — model geometry only, no
    /// motion. The one materialization path for pre-fill, steady spawns, and
    /// scrub backfill.
    private func materializeBubble(
        _ item: TickerCommentModel, atIndex itemIndex: Int, lane: Int, leftEdge: CGFloat, width: CGFloat
    ) -> Bubble {
        let label = dequeueBubble()
        label.text = item.text
        label.frame = CGRect(
            x: leftEdge,
            y: CGFloat(lane) * (bubbleHeight + Self.laneSpacing),
            width: width,
            height: bubbleHeight
        )
        addSubview(label)
        return Bubble(label: label, width: width, itemIndex: itemIndex)
    }

    /// Flies a bubble from wherever its model currently sits to the exit at
    /// the lane's constant speed — the single flight path, so pre-filled,
    /// entry-edge, and scrub-released bubbles cannot differ in velocity.
    private func animateToExit(_ bubble: Bubble, lane: Int) {
        let layer = bubble.label.layer
        let startX = layer.position.x
        let exitX = -bubble.width / 2
        guard startX > exitX else { return }
        bubble.flightStartX = startX
        bubble.flightStartTime = CACurrentMediaTime()

        let flight = CABasicAnimation(keyPath: "position.x")
        flight.fromValue = startX
        flight.toValue = exitX
        flight.duration = CFTimeInterval((startX - exitX) / Self.laneSpeeds[lane])
        flight.timingFunction = CAMediaTimingFunction(name: .linear)

        let flightGeneration = generation
        let label = bubble.label
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, flightGeneration == self.generation else { return }
            self.laneBubbles[lane].removeAll { $0.label === label }
            self.recycle(label)
        }
        // Model value rests at the exit before the animation is added, so if
        // the system strips animations the bubble sits off screen left rather
        // than snapping back to the entry edge.
        layer.position.x = exitX
        layer.add(flight, forKey: "flight")
        CATransaction.commit()
    }

    // MARK: - Manual scrub

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            lastPanTranslation = 0
            beginScrub()
            // Feedback engages with the grab itself, before any movement.
            setBlurIntensity(Self.scrubFraction(forAccumulatedDistance: 0))
        case .changed:
            let translation = pan.translation(in: self).x
            applyScrubTranslation(translation - lastPanTranslation)
            lastPanTranslation = translation
            // Accumulator only: no velocity term while the finger is down,
            // so the intensity can rise or hold but never drop mid-touch.
            setBlurIntensity(Self.scrubFraction(forAccumulatedDistance: scrubAccumulatedDistance))
        case .ended, .cancelled, .failed:
            endScrub(releaseVelocity: pan.velocity(in: self).x)
        default:
            break
        }
    }

    /// Takes the conveyor away from Core Animation: every bubble's on-screen
    /// (presentation) position becomes its model position and the flight is
    /// removed — the standard interruptible-animation takeover. Bumping the
    /// generation first turns the flights' pending completions into no-ops,
    /// so the pool is untouched.
    func beginScrub() {
        switch mode {
        case .parked, .scrubbing:
            return
        case .coasting:
            stopCoast() // grab mid-decay: positions are already model-owned
        case .conveying:
            generation += 1
            for timer in spawnTimers { timer?.invalidate() }
            spawnTimers = Array(repeating: nil, count: Self.laneCount)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for lane in 0..<Self.laneCount {
                for bubble in laneBubbles[lane] {
                    let layer = bubble.label.layer
                    let frozenX = currentVisualCenterX(of: bubble, lane: lane)
                    layer.removeAnimation(forKey: "flight")
                    layer.position.x = frozenX
                }
            }
            CATransaction.commit()
        }
        mode = .scrubbing
        scrubAccumulatedDistance = 0 // each touch is its own accumulation lifecycle
    }

    /// Direct manipulation: the whole band tracks the finger by `dx`, then
    /// both edges are re-normalized from the wrap-around queue. Every delta
    /// feeds the accumulator by its absolute value — back-and-forth travel
    /// builds intensity; nothing subtracts.
    func applyScrubTranslation(_ dx: CGFloat) {
        guard mode == .scrubbing else { return }
        scrubAccumulatedDistance += abs(dx)
        displaceLanes(by: Array(repeating: dx, count: Self.laneCount))
    }

    /// Release: relax each lane from the finger's velocity back to its
    /// steady drift. If the release is already indistinguishable from the
    /// drift, hand straight back to CA; otherwise integrate the decay on a
    /// display link that lives only for this transient.
    func endScrub(releaseVelocity: CGFloat) {
        guard mode == .scrubbing else { return }
        coastReleaseFraction = Self.scrubFraction(forAccumulatedDistance: scrubAccumulatedDistance)
        let maxResidual = Self.laneSpeeds
            .map { abs(releaseVelocity - (-$0)) }
            .max() ?? 0
        guard maxResidual > Self.restVelocityTolerance else {
            resumeConveying()
            return
        }
        mode = .coasting
        coastReleaseVelocity = releaseVelocity
        coastStart = CACurrentMediaTime()
        coastLastTimestamp = coastStart
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        coastLink = link
    }

    /// Residual-decay velocity for one lane, `elapsed` seconds after release:
    /// `v(t) = drift + (V₀ - drift)·e^(-t/τ)`. Pure — the handover contract
    /// (converges to drift, never overshoots) is unit-testable.
    static func coastVelocity(
        release: CGFloat, steadyDrift: CGFloat, elapsed: TimeInterval, tau: TimeInterval = decayTimeConstant
    ) -> CGFloat {
        steadyDrift + (release - steadyDrift) * CGFloat(exp(-elapsed / tau))
    }

    fileprivate func coastTick(_ link: CADisplayLink) {
        coastStep(now: link.timestamp)
    }

    /// One decay integration step, separated from the display link so the
    /// coast is deterministically drivable in tests.
    func coastStep(now: CFTimeInterval) {
        guard mode == .coasting else {
            stopCoast()
            return
        }
        let dt = CGFloat(now - coastLastTimestamp)
        coastLastTimestamp = now
        let elapsed = now - coastStart

        var maxResidual: CGFloat = 0
        var laneDx: [CGFloat] = []
        for lane in 0..<Self.laneCount {
            let drift = -Self.laneSpeeds[lane]
            let velocity = Self.coastVelocity(release: coastReleaseVelocity, steadyDrift: drift, elapsed: elapsed)
            maxResidual = max(maxResidual, abs(velocity - drift))
            laneDx.append(velocity * dt)
        }
        displaceLanes(by: laneDx)
        // The fade envelope starts at the value held at release (the
        // accumulator's peak) and relaxes on the same exponential clock as
        // the velocities — continuous at lift-off, zero at handover.
        setBlurIntensity(coastReleaseFraction * CGFloat(exp(-elapsed / Self.decayTimeConstant)))

        if maxResidual < Self.restVelocityTolerance {
            stopCoast()
            resumeConveying()
        }
    }

    private func stopCoast() {
        coastLink?.invalidate()
        coastLink = nil
    }

    /// Hands the band back to the render server: every bubble flies from its
    /// current (model) position to the exit at lane speed — velocity-matched
    /// to the decayed drift within `restVelocityTolerance`, so the handover
    /// is invisible — and the entry cadence resumes from the actual gap at
    /// the right edge.
    private func resumeConveying() {
        mode = .conveying
        dismissKineticBackdrop()
        let bandWidth = bounds.width
        for lane in 0..<Self.laneCount {
            // A scrub can strand a bubble past the exit (model position ≤
            // exit); `animateToExit` skips those — retire them here.
            var kept: [Bubble] = []
            for bubble in laneBubbles[lane] {
                if bubble.label.layer.position.x <= -bubble.width / 2 {
                    recycle(bubble.label)
                } else {
                    kept.append(bubble)
                }
            }
            laneBubbles[lane] = kept
            for bubble in laneBubbles[lane] {
                animateToExit(bubble, lane: lane)
            }
            let speed = Self.laneSpeeds[lane]
            if let last = laneBubbles[lane].last {
                let rightEdge = last.label.layer.position.x + last.width / 2
                armSpawn(lane: lane, after: TimeInterval(max(0, (rightEdge + Self.interItemGap - bandWidth) / speed)))
            } else {
                armSpawn(lane: lane, after: 0)
            }
        }
    }

    /// Moves each lane by its own dx (identical during a drag, per-lane
    /// during the decay), then retires what left the scrub margin and
    /// backfills both edges from the wrap-around queue — scrubbing has no
    /// holes in either direction.
    private func displaceLanes(by laneDx: [CGFloat]) {
        let bandWidth = bounds.width
        guard bandWidth > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for lane in 0..<Self.laneCount where !laneQueues[lane].isEmpty {
            for bubble in laneBubbles[lane] {
                bubble.label.layer.position.x += laneDx[lane]
            }
            normalizeLaneEdges(lane, bandWidth: bandWidth)
        }
        CATransaction.commit()
    }

    private func normalizeLaneEdges(_ lane: Int, bandWidth: CGFloat) {
        let count = laneQueues[lane].count

        // Retire beyond the margins. A right-edge retire "un-consumes" its
        // queue slot so the item reappears when scrubbed back.
        while let first = laneBubbles[lane].first,
              first.label.layer.position.x + first.width / 2 < -Self.scrubMargin {
            recycle(first.label)
            laneBubbles[lane].removeFirst()
        }
        while let last = laneBubbles[lane].last,
              last.label.layer.position.x - last.width / 2 > bandWidth + Self.scrubMargin {
            recycle(last.label)
            laneBubbles[lane].removeLast()
            laneNextIndex[lane] = last.itemIndex
        }

        // An emptied lane re-anchors at the entry edge before backfilling.
        if laneBubbles[lane].isEmpty {
            let itemIndex = laneNextIndex[lane]
            let item = laneItem(lane, at: itemIndex)
            laneNextIndex[lane] = wrapped(itemIndex + 1, count)
            let width = measuredBubbleWidth(for: item.text, in: bandWidth)
            laneBubbles[lane] = [materializeBubble(item, atIndex: itemIndex, lane: lane, leftEdge: bandWidth - width, width: width)]
        }

        // Backfill right (scrubbing forward pulls future items in early).
        while let last = laneBubbles[lane].last {
            let lastRight = last.label.layer.position.x + last.width / 2
            guard lastRight + Self.interItemGap < bandWidth + Self.scrubMargin else { break }
            let itemIndex = laneNextIndex[lane]
            let item = laneItem(lane, at: itemIndex)
            laneNextIndex[lane] = wrapped(itemIndex + 1, count)
            let width = measuredBubbleWidth(for: item.text, in: bandWidth)
            laneBubbles[lane].append(
                materializeBubble(item, atIndex: itemIndex, lane: lane, leftEdge: lastRight + Self.interItemGap, width: width)
            )
        }

        // Backfill left (scrubbing backward rewinds into already-shown items).
        while let first = laneBubbles[lane].first {
            let firstLeft = first.label.layer.position.x - first.width / 2
            guard firstLeft - Self.interItemGap > -Self.scrubMargin else { break }
            let itemIndex = wrapped(first.itemIndex - 1, count)
            let item = laneItem(lane, at: itemIndex)
            let width = measuredBubbleWidth(for: item.text, in: bandWidth)
            laneBubbles[lane].insert(
                materializeBubble(item, atIndex: itemIndex, lane: lane, leftEdge: firstLeft - Self.interItemGap - width, width: width),
                at: 0
            )
        }
    }

    // MARK: - Kinetic blur

    /// The engaged surface's current fraction (0 when disengaged) — the
    /// deterministic observable for tests; actual rendering needs a window.
    var currentKineticFraction: CGFloat { blurAnimator?.fractionComplete ?? 0 }

    /// Drives the paused animator's `fractionComplete`. Zero is the hard
    /// teardown (page deactivation); the graceful end of an interaction is
    /// `dismissKineticBackdrop`.
    private func setBlurIntensity(_ fraction: CGFloat) {
        if fraction <= 0 {
            if let animator = blurAnimator {
                animator.stopAnimation(true) // → .inactive: safe to release
                animatorBag.release(animator)
                blurAnimator = nil
            }
            if let dismissing = blurDismissAnimator {
                dismissing.stopAnimation(true)
                animatorBag.release(dismissing)
                blurDismissAnimator = nil
            }
            blurView.effect = nil
            blurView.isHidden = true
            return
        }
        // A re-grab mid-dismissal stops the reversal and takes back over.
        if let dismissing = blurDismissAnimator {
            dismissing.stopAnimation(true)
            animatorBag.release(dismissing)
            blurDismissAnimator = nil
        }
        if blurAnimator == nil {
            blurView.isHidden = false
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [blurView] in
                blurView.effect = UIBlurEffect(style: .systemThickMaterial)
            }
            // An animator left `.inactive` silently ignores
            // `fractionComplete`; pausing activates it.
            animator.pauseAnimation()
            animatorBag.adopt(animator)
            blurAnimator = animator
        }
        blurAnimator?.fractionComplete = fraction
    }

    /// Ends the interaction's feedback by REVERSING the paused animator —
    /// UIKit animates the material itself back to nothing (fading an effect
    /// view's alpha breaks blur rendering). Releasing from a stationary hold
    /// sits at the accumulator's peak, and popping that off reads as a
    /// glitch; a dismissal from a fast coast is equally fine, the fraction
    /// has already decayed to almost nothing.
    private func dismissKineticBackdrop() {
        guard let animator = blurAnimator else { return }
        blurAnimator = nil
        blurDismissAnimator = animator
        animator.isReversed = true
        animator.addCompletion { [weak self] _ in
            guard let self, self.blurDismissAnimator === animator else { return }
            self.blurDismissAnimator = nil
            self.animatorBag.release(animator) // finished naturally: safe
            self.blurView.effect = nil
            self.blurView.isHidden = true
        }
        animator.continueAnimation(withTimingParameters: nil, durationFactor: 0.25)
    }

    /// The bubble's on-screen center-x: the render server's truth when
    /// available (authoritative even while an interactive transition freezes
    /// the layer clock), else the analytic flight position (start −
    /// speed·elapsed, for a flight grabbed before its first committed
    /// frame), else the model (scrub-owned bubbles). The parked model value
    /// of an in-flight bubble must never be used — it rests at the exit by
    /// design.
    private func currentVisualCenterX(of bubble: Bubble, lane: Int) -> CGFloat {
        let layer = bubble.label.layer
        if let presented = layer.presentation() {
            return presented.position.x
        }
        if layer.animation(forKey: "flight") != nil {
            return max(
                -bubble.width / 2,
                bubble.flightStartX - Self.laneSpeeds[lane]
                    * CGFloat(CACurrentMediaTime() - bubble.flightStartTime)
            )
        }
        return layer.position.x
    }

    // MARK: - Queue & pool plumbing

    private func laneItem(_ lane: Int, at index: Int) -> TickerCommentModel {
        laneQueues[lane][wrapped(index, laneQueues[lane].count)]
    }

    private func wrapped(_ index: Int, _ count: Int) -> Int {
        ((index % count) + count) % count
    }

    private func measuredBubbleWidth(for text: String, in bandWidth: CGFloat) -> CGFloat {
        measuringBubble.text = text
        let fitted = measuringBubble.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: bubbleHeight))
        return min(ceil(fitted.width), bandWidth * 0.9)
    }

    private func dequeueBubble() -> TickerBubbleLabel {
        pool.popLast() ?? TickerBubbleLabel()
    }

    private func recycle(_ bubble: TickerBubbleLabel) {
        bubble.removeFromSuperview()
        bubble.text = nil
        // Steady state needs a handful per lane; a wide scrub can hold a few
        // more. Anything beyond is a transient and can be released.
        if pool.count < 24 { pool.append(bubble) }
    }
}

// MARK: - Gesture priority

extension SnapCommentTickerView: UIGestureRecognizerDelegate {
    /// The band owns horizontal gestures inside its own frame: any OTHER pan
    /// hearing the same touches — the timeline slide-to-pop, the pin grab,
    /// the vertical pager — must wait for the band's pan to fail first.
    /// Failure is fast (vertical intent fails in `shouldBegin`), so page
    /// scrolls aren't perceptibly delayed; rightward scrubs stop being
    /// stolen by the interactive dismissal.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === panRecognizer && otherGestureRecognizer is UIPanGestureRecognizer
    }
}

/// Settles the ticker's property animators when it is released: UIKit
/// throws on deallocating a paused (or stopped-but-unfinished)
/// `UIViewPropertyAnimator`, and a ticker can die while one is engaged
/// (mid-interaction teardown, test teardown). `@unchecked Sendable` because
/// its deinit may run off the main actor; the drain hops to the main queue,
/// which also keeps the orphans alive until UIKit can finalize them there.
private final class KineticAnimatorBag: @unchecked Sendable {
    private struct Orphans: @unchecked Sendable {
        let animators: [UIViewPropertyAnimator]
    }

    private var animators: [UIViewPropertyAnimator] = []

    func adopt(_ animator: UIViewPropertyAnimator) {
        animators.append(animator)
    }

    /// Call once an animator is safe to release (stopped-without-finishing →
    /// `.inactive`, or finished naturally).
    func release(_ animator: UIViewPropertyAnimator) {
        animators.removeAll { $0 === animator }
    }

    deinit {
        guard !animators.isEmpty else { return }
        let orphans = Orphans(animators: animators)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for animator in orphans.animators {
                    switch animator.state {
                    case .active:
                        animator.stopAnimation(false)
                        animator.finishAnimation(at: .current)
                    case .stopped:
                        animator.finishAnimation(at: .current)
                    default:
                        break
                    }
                }
            }
        }
    }
}

/// Breaks the CADisplayLink → target retain cycle so a mid-coast cell
/// teardown can't leak the band. Main-actor because the link is scheduled on
/// the main run loop — ticks arrive there by construction.
@MainActor
private final class DisplayLinkProxy: NSObject {
    private weak var ticker: SnapCommentTickerView?

    init(_ ticker: SnapCommentTickerView) { self.ticker = ticker }

    @objc func tick(_ link: CADisplayLink) {
        guard let ticker else {
            link.invalidate()
            return
        }
        ticker.coastTick(link)
    }
}

/// A pooled danmaku label: naked semibold caption text, no capsule, no
/// border — legibility comes from the chrome's extended scrim, and
/// deliberately NOT from `layer.shadow*` (a shadow on a moving layer forces
/// an offscreen render pass per frame per bubble over the video).
private final class TickerBubbleLabel: UILabel {
    static let textInsets = UIEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)

    init() {
        super.init(frame: .zero)
        font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        textColor = .white
        lineBreakMode = .byTruncatingTail
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: Self.textInsets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(size)
        return CGSize(
            width: fitted.width + Self.textInsets.left + Self.textInsets.right,
            height: fitted.height + Self.textInsets.top + Self.textInsets.bottom
        )
    }
}
