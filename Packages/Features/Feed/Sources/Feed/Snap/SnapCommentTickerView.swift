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
    static let laneSpeeds: [CGFloat] = [25, 32, 38]
    /// First-spawn offsets per lane, so a fresh stream doesn't enter as a
    /// rigid three-row column; scaled with the gentle speeds.
    static let laneLeadDelays: [TimeInterval] = [0.3, 1.5, 2.7]
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
        stopStream()
        queue = comments
        nextIndex = 0
        isHidden = comments.isEmpty || UIAccessibility.isReduceMotionEnabled
        startIfNeeded()
    }

    /// Rides the cell's `SnapCellLifecycle`: only the settled, foreground,
    /// on-screen page streams.
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
            armSpawn(lane: lane, after: Self.laneLeadDelays[lane])
        }
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

    private func spawn(inLane lane: Int) {
        let bandWidth = bounds.width
        guard isStreaming, !queue.isEmpty, bandWidth > 0 else { return }

        let item = queue[nextIndex % queue.count]
        nextIndex = (nextIndex + 1) % queue.count // infinite wrap-around

        let bubble = dequeueBubble()
        bubble.text = item.text
        let fitted = bubble.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: bubbleHeight))
        let bubbleWidth = min(ceil(fitted.width), bandWidth * 0.9)
        bubble.frame = CGRect(
            x: bandWidth,
            y: CGFloat(lane) * (bubbleHeight + Self.laneSpacing),
            width: bubbleWidth,
            height: bubbleHeight
        )
        bubble.layer.cornerRadius = bubbleHeight / 2
        addSubview(bubble)
        flying.append(bubble)

        let speed = Self.laneSpeeds[lane]
        let flight = CABasicAnimation(keyPath: "position.x")
        flight.fromValue = bandWidth + bubbleWidth / 2
        flight.toValue = -bubbleWidth / 2
        flight.duration = CFTimeInterval((bandWidth + bubbleWidth) / speed)
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
        bubble.layer.position.x = -bubbleWidth / 2
        bubble.layer.add(flight, forKey: "flight")
        CATransaction.commit()

        // This lane may spawn again once this bubble has fully entered plus
        // the gap; at constant per-lane speed that guarantees no overlap.
        armSpawn(lane: lane, after: TimeInterval((bubbleWidth + Self.interItemGap) / speed))
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
