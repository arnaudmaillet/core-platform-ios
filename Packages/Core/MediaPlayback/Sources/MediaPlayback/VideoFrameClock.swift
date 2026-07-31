import QuartzCore

/// The one `CADisplayLink` the video subsystem owns, shared by every renderer.
///
/// Six autoplaying grid tiles must not mean six display links: each one is a
/// separate run-loop source woken on every screen refresh, and at 120Hz that is
/// six wakeups per 8ms to do work that coalesces perfectly into one. Renderers
/// register here instead, and the link exists only while at least one of them
/// wants frames.
///
/// **The link runs at full refresh rate on purpose.** It is tempting to cap
/// `preferredFrameRateRange` to the content's ~30fps, but the tick is not what
/// costs — `hasNewPixelBuffer(forItemTime:)` is a cheap comparison, and it is
/// what gates the actual work, so a 30fps clip does ~30 pulls per second no
/// matter how often we look. What a capped link *would* cost is scanout
/// accuracy: we ask the video output for the frame correct at
/// `targetTimestamp`, and looking less often than the display refreshes means
/// systematically presenting frames at the wrong refresh.
@MainActor
final class VideoFrameClock {
    static let shared = VideoFrameClock()

    /// Weak: a renderer that its controller has released should stop being
    /// ticked without needing to say so. `allObjects` is snapshotted per tick,
    /// so a renderer detaching mid-tick cannot mutate the table underneath us.
    private let renderers = NSHashTable<VideoFrameRenderer>.weakObjects()
    private var link: CADisplayLink?

    private init() {}

    func add(_ renderer: VideoFrameRenderer) {
        guard !renderers.contains(renderer) else { return }
        renderers.add(renderer)
        startIfNeeded()
    }

    func remove(_ renderer: VideoFrameRenderer) {
        renderers.remove(renderer)
        stopIfIdle()
    }

    private func startIfNeeded() {
        guard link == nil, renderers.count > 0 else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // `.common`, not `.default`: a grid tile has to keep receiving frames
        // while the collection view is being dragged, and tracking mode is
        // exactly when the tiles are moving and a freeze is most visible.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopIfIdle() {
        guard renderers.count == 0 else { return }
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        // `targetTimestamp`, not `timestamp`: the former is when this frame will
        // actually reach the display. Pacing off `timestamp` presents each frame
        // one refresh late, which at 120Hz is a consistent half-frame of lag
        // against the player's own clock — the thing that becomes audible drift
        // once Phase 3 unmutes the feed.
        let hostTime = link.targetTimestamp
        var live = 0
        for renderer in renderers.allObjects {
            renderer.render(atHostTime: hostTime)
            live += 1
        }
        // A renderer deallocated between registration and now leaves the table
        // empty without anyone calling `remove`; reap the link so an idle app
        // is not woken 120 times a second forever.
        if live == 0 { stopIfIdle() }
    }
}
