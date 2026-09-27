import UIKit

/// Whether a view can actually be SEEN — the test a label passes before it
/// may hold one of `EmoteEngine.maxAnimatedEmotes` animation slots.
///
/// `window != nil && !isHidden` is not it: a collection view keeps cells it
/// is not showing attached and hidden, and a pager keeps its neighbour pages
/// attached, visible and out of its bounds. Measured before this existed: a
/// comments list showing ~16 emotes held 38–41 of the 48 slots, and a feed
/// page showing 6 held 20 — a longer list would have left VISIBLE emotes
/// static.
@MainActor
enum EmoteVisibility {
    /// Below this, UIKit itself treats a view as invisible (hit-testing).
    static let alphaThreshold: CGFloat = 0.01

    /// In a window, nothing on the way up hidden or transparent, and some of
    /// the view's bounds inside every clipping ancestor (a scroll view clips)
    /// and inside the window.
    ///
    /// One walk up the hierarchy, converting the rect a level at a time — a
    /// few microseconds for a label twenty views deep.
    static func isEffectivelyVisible(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        var rect = view.bounds
        var current = view
        while true {
            if current.isHidden || current.alpha < alphaThreshold { return false }
            guard let parent = current.superview else { break }
            rect = current.convert(rect, to: parent)
            if parent.clipsToBounds, !rect.intersects(parent.bounds) { return false }
            current = parent
        }
        return current === window && rect.intersects(window.bounds)
    }
}

/// Re-checks the visibility of every label that has emotes and a window,
/// a few times a second, while there is at least one.
///
/// Nothing tells a label that an ANCESTOR was hidden, faded out or scrolled
/// away — it gets no layout pass for any of those. A timer is the cheap,
/// complete answer: a tick costs a hierarchy walk per registered label, runs in
/// the COMMON modes (so a scroll that carries a page out frees its slots
/// without waiting for the finger to lift), and stops when no label is
/// registered.
@MainActor
final class EmoteVisibilityMonitor {
    static let shared = EmoteVisibilityMonitor()

    /// How often labels are re-checked. A label that scrolls INTO view shows
    /// its glyph for at most this long before animating; one that leaves
    /// gives its slot back within it.
    static let interval: TimeInterval = 0.25

    private let labels = NSHashTable<EmoteLabel>.weakObjects()
    private var timer: Timer?

    var isRunning: Bool { timer != nil }
    var registeredCount: Int { labels.allObjects.count }

    func register(_ label: EmoteLabel) {
        labels.add(label)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { EmoteVisibilityMonitor.shared.tick() }
        }
        timer.tolerance = Self.interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func unregister(_ label: EmoteLabel) {
        labels.remove(label)
        if labels.allObjects.isEmpty { stop() }
    }

    /// One pass over every registered label.
    func tick() {
        let live = labels.allObjects
        guard !live.isEmpty else {
            stop()
            return
        }
        live.forEach { $0.reevaluateVisibility() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
