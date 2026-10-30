import QuartzCore

/// A grab's frame pacing (#1915): how long each frame took while the page was
/// held, and while its release settled — the cost of drawing the live page,
/// its whole interface and its playing clip, at a scale.
///
/// The arithmetic is pure, for tests; the sampler that feeds it is DEBUG
/// (`-grab-frames`).
public struct GrabFramePacing: Equatable, Sendable {
    /// Frames sampled.
    public let frames: Int
    /// The display's frame interval the link asked for.
    public let expected: CFTimeInterval
    public let median: CFTimeInterval
    public let p95: CFTimeInterval
    public let worst: CFTimeInterval
    /// Frames that took longer than one and a half expected intervals: at
    /// least one display refresh was missed.
    public let hitches: Int

    /// Nil with nothing to measure.
    public init?(intervals: [CFTimeInterval], expected: CFTimeInterval) {
        let sorted = intervals.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty, expected > 0 else { return nil }
        func percentile(_ p: Double) -> CFTimeInterval {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        frames = sorted.count
        self.expected = expected
        median = percentile(0.5)
        p95 = percentile(0.95)
        worst = sorted[sorted.count - 1]
        hitches = sorted.filter { $0 > expected * 1.5 }.count
    }

    /// One line for the log, in milliseconds.
    public var line: String {
        String(format: "%d frames @%.1fms: median %.1fms, p95 %.1fms, worst %.1fms, %d hitches",
               frames, expected * 1000, median * 1000, p95 * 1000, worst * 1000, hitches)
    }
}

#if DEBUG
/// Samples every frame of a grab under `-grab-frames`, and prints the held
/// stretch and the release apart: the live page costs while it is held, the
/// release is the flight's.
@MainActor
final class GrabFramePacer {
    static let shared = GrabFramePacer()
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-grab-frames") }

    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var expected: CFTimeInterval = 0
    private var held: [CFTimeInterval] = []
    private var release: [CFTimeInterval] = []
    private var isReleased = false

    func start() {
        guard Self.isOn else { return }
        stop(outcome: nil)
        held = []
        release = []
        isReleased = false
        last = nil
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The finger lifted: what follows is the release's.
    func released() { isReleased = true }

    /// Prints both stretches; nil outcome prints nothing (a restart).
    func stop(outcome: String?) {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        guard let outcome else { return }
        let heldLine = GrabFramePacing(intervals: held, expected: expected)?.line ?? "none"
        let releaseLine = GrabFramePacing(intervals: release, expected: expected)?.line ?? "none"
        print("[grab-frames] \(outcome) held: \(heldLine)")
        print("[grab-frames] \(outcome) release: \(releaseLine)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        expected = link.targetTimestamp - link.timestamp
        if let last {
            let interval = link.timestamp - last
            if isReleased { release.append(interval) } else { held.append(interval) }
        }
        last = link.timestamp
    }
}
#endif
