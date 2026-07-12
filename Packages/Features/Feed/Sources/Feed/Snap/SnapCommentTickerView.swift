import UIKit

/// The danmaku band: three lanes of short comments conveying right-to-left
/// over the page's media, stacked between the caption and the media above it.
///
/// The engine is pure Core Animation. Each bubble's flight is one linear
/// `CABasicAnimation` on `position.x`, executed entirely on the render server:
/// the main thread is touched only at spawn/retire (a few times per second),
/// so the stream stays fluid at the display's native rate over playing video
/// and is immune to main-thread hitches. There is no display link and no
/// scroll view — a lane holds at most a handful of bubbles, recycled through
/// a small pool.
///
/// Density and organic flow come from the lane scheduling: each lane runs at
/// its own constant speed (staggered across lanes, never within one — a
/// faster follower would overtake a slower leader) and spawns its next bubble
/// only once the previous one has fully entered plus a gap, so a lane can
/// never overlap itself. The queue wraps around indefinitely.
///
/// There is no cold start: activation PRE-FILLS every lane as if the stream
/// had always been running — bubbles laid across the visible band at
/// steady-state spacing, each animated to the exit over its remaining
/// distance at the lane's constant speed, and the first fresh spawn timed to
/// continue exactly the cadence the fill implies. The band lands populated
/// and moving on its first frame, and the handover to the entry-edge loop is
/// seamless by construction (same speed, same gap arithmetic).
///
/// Lifecycle is a hard stop/start, not a freeze: `setActive(false)` retires
/// everything in flight. Every path that deactivates a page (swipe away,
/// backgrounding, pop) also takes the band off screen, so nothing is ever
/// seen stopping — and stopping outright is what makes backgrounding safe,
/// since the system strips CA animations from backgrounded apps.
final class SnapCommentTickerView: UIView {
    static let laneCount = 3
    /// Per-lane speeds (pt/s). Deliberately staggered and incommensurate so
    /// the three lanes drift out of phase instead of moving as a block.
    /// Calibrated low: the band is a micro-reaction dump and should glide
    /// calmly under the media, not race across it.
    static let laneSpeeds: [CGFloat] = [22, 26, 24]
    /// Per-lane phase, in seconds of travel. The pre-fill shifts each lane's
    /// bubble train left by `phase × speed` points — as if that lane had
    /// entered the loop this much earlier — so the three lanes land visibly
    /// out of step instead of column-aligned at the left edge.
    static let lanePhases: [TimeInterval] = [0.3, 1.5, 2.7]
    /// Minimum horizontal daylight between two bubbles in the same lane —
    /// generous, so the slow glide reads sparse rather than congested.
    static let interItemGap: CGFloat = 32
    private static let laneSpacing: CGFloat = 3

    private let bubbleHeight: CGFloat
    private var queue: [TickerCommentModel] = []
    /// Next queue index to spawn, shared by all lanes; wraps around so the
    /// stream is infinite.
    private var nextIndex = 0
    /// Mirrors the owning cell's active-page state; content may arrive before
    /// or after activation, so both paths funnel into `startIfNeeded`.
    private var isActive = false
    private var isStreaming = false
    /// Invalidates in-flight CA completion blocks across a stop: completions
    /// fire even for removed animations, and a stale one must not touch a
    /// bubble that a newer stream already owns.
    private var generation = 0
    private var spawnTimers: [Timer?] = Array(repeating: nil, count: SnapCommentTickerView.laneCount)
    private var flying: [TickerBubbleLabel] = []
    private var pool: [TickerBubbleLabel] = []
    /// Measures widths without touching the pool — the pre-fill must know a
    /// bubble's width before deciding whether it is even on screen.
    private let measuringBubble = TickerBubbleLabel()

    override init(frame: CGRect) {
        bubbleHeight = ceil(UIFont.preferredFont(forTextStyle: .caption1).lineHeight)
            + TickerBubbleLabel.textInsets.top + TickerBubbleLabel.textInsets.bottom
        super.init(frame: frame)
        // Passive by construction: taps fall through to the cell's playback
        // toggle, and the chrome's `interactionRoots` never mention the band.
        isUserInteractionEnabled = false
        isHidden = true
        // No clipping: bubbles spawn just past the trailing edge, which is
        // already off screen (the band spans the page's full width), and the
        // cell's own `clipsToBounds` bounds the rest.
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
        nextIndex = 0
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
        nextIndex = 0
        isHidden = true
        alpha = 1 // a reuse mid-entrance-fade must not strand a dim band
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Activation can precede first layout (configure → willBecomeActive
        // before the cell is sized); spawning needs a real width.
        startIfNeeded()
    }

    // MARK: - Lane scheduling

    private func startIfNeeded() {
        guard isActive, !isStreaming, !queue.isEmpty, bounds.width > 0,
              !UIAccessibility.isReduceMotionEnabled else { return }
        isStreaming = true
        for lane in 0..<Self.laneCount {
            prefillLane(lane)
        }
    }

    /// Populates one lane the way it would look mid-stream: a left-to-right
    /// train of bubbles at steady-state spacing (each width + gap apart),
    /// phase-shifted left so lanes don't align, every bubble flying at the
    /// lane's constant speed over exactly its remaining distance. The cursor
    /// ends past the entry edge; the delay until the next real spawn is that
    /// overshoot at lane speed, so the loop's cadence continues the fill's
    /// without a seam, and the entry-gap invariant holds across the handover.
    private func prefillLane(_ lane: Int) {
        let bandWidth = bounds.width
        let speed = Self.laneSpeeds[lane]
        var cursor = -CGFloat(Self.lanePhases[lane]) * speed
        while cursor < bandWidth {
            let item = takeNextItem()
            let width = measuredBubbleWidth(for: item.text, in: bandWidth)
            // A slot wholly left of the band is a bubble that "already
            // exited": consume its queue slot (the wrap-around doesn't care)
            // but materialize nothing.
            if cursor + width > 0 {
                launchBubble(item, lane: lane, leftEdge: cursor, width: width)
            }
            cursor += width + Self.interItemGap
        }
        armSpawn(lane: lane, after: TimeInterval((cursor - bandWidth) / speed))
    }

    private func stopStream() {
        generation += 1
        isStreaming = false
        for timer in spawnTimers { timer?.invalidate() }
        spawnTimers = Array(repeating: nil, count: Self.laneCount)
        for bubble in flying {
            bubble.layer.removeAllAnimations()
            recycle(bubble)
        }
        flying.removeAll()
    }

    private func armSpawn(lane: Int, after delay: TimeInterval) {
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.spawn(inLane: lane) }
        }
        // Spawn timing is not frame-precise work; tolerance keeps the timer
        // cheap while video plays.
        timer.tolerance = max(0.05, delay * 0.1)
        spawnTimers[lane] = timer
    }

    /// The steady loop: one fresh bubble at the entry edge, then re-arm for
    /// when it has fully entered plus the gap — at constant per-lane speed
    /// that guarantees no overlap.
    private func spawn(inLane lane: Int) {
        let bandWidth = bounds.width
        guard isStreaming, !queue.isEmpty, bandWidth > 0 else { return }

        let item = takeNextItem()
        let width = measuredBubbleWidth(for: item.text, in: bandWidth)
        launchBubble(item, lane: lane, leftEdge: bandWidth, width: width)
        armSpawn(lane: lane, after: TimeInterval((width + Self.interItemGap) / Self.laneSpeeds[lane]))
    }

    private func takeNextItem() -> TickerCommentModel {
        let item = queue[nextIndex % queue.count]
        nextIndex = (nextIndex + 1) % queue.count // infinite wrap-around
        return item
    }

    private func measuredBubbleWidth(for text: String, in bandWidth: CGFloat) -> CGFloat {
        measuringBubble.text = text
        let fitted = measuringBubble.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: bubbleHeight))
        return min(ceil(fitted.width), bandWidth * 0.9)
    }

    /// The one flight path for both origins — pre-filled mid-band and steady
    /// entry-edge spawns: place at `leftEdge`, fly to the exit over exactly
    /// the remaining distance at the lane's constant speed. One code path
    /// means the handover cannot change velocity or stutter.
    private func launchBubble(_ item: TickerCommentModel, lane: Int, leftEdge: CGFloat, width: CGFloat) {
        let bubble = dequeueBubble()
        bubble.text = item.text
        bubble.frame = CGRect(
            x: leftEdge,
            y: CGFloat(lane) * (bubbleHeight + Self.laneSpacing),
            width: width,
            height: bubbleHeight
        )
        bubble.layer.cornerRadius = bubbleHeight / 2
        addSubview(bubble)
        flying.append(bubble)

        let startX = leftEdge + width / 2
        let exitX = -width / 2
        let flight = CABasicAnimation(keyPath: "position.x")
        flight.fromValue = startX
        flight.toValue = exitX
        flight.duration = CFTimeInterval((startX - exitX) / Self.laneSpeeds[lane])
        flight.timingFunction = CAMediaTimingFunction(name: .linear)

        let flightGeneration = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, flightGeneration == self.generation else { return }
            self.flying.removeAll { $0 === bubble }
            self.recycle(bubble)
        }
        // Model value rests at the exit before the animation is added, so if
        // the system strips animations the bubble sits off screen left rather
        // than snapping back to the entry edge.
        bubble.layer.position.x = exitX
        bubble.layer.add(flight, forKey: "flight")
        CATransaction.commit()
    }

    // MARK: - Bubble pool

    private func dequeueBubble() -> TickerBubbleLabel {
        pool.popLast() ?? TickerBubbleLabel()
    }

    private func recycle(_ bubble: TickerBubbleLabel) {
        bubble.removeFromSuperview()
        bubble.text = nil
        // Steady state needs ~4 bubbles per lane; anything beyond that is a
        // transient and can be released.
        if pool.count < 16 { pool.append(bubble) }
    }
}

/// A pooled danmaku bubble: white caption text on a translucent capsule.
/// Legibility comes from the capsule fill, NOT `layer.shadow*` — a shadow on
/// a moving layer forces an offscreen render pass per frame per bubble over
/// the video.
private final class TickerBubbleLabel: UILabel {
    static let textInsets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)

    init() {
        super.init(frame: .zero)
        font = .preferredFont(forTextStyle: .caption1)
        textColor = .white
        lineBreakMode = .byTruncatingTail
        isUserInteractionEnabled = false
        // Background on the layer (not the view) so cornerRadius rounds it
        // without masksToBounds; both composite directly, no offscreen pass.
        layer.backgroundColor = UIColor.black.withAlphaComponent(0.35).cgColor
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
