#if DEBUG
import UIKit

/// `-scroll-stop-trace`: what ends each deceleration of a grid page — the
/// instrument for "a fast fling stops dead mid-deceleration" (#2097).
///
/// On one clock (`CACurrentMediaTime`, ms since the page's first event):
/// - every release (velocity, target), and every deceleration's end: how fast
///   it was still going on its last frame, and whether UIKit said so
///   (`scrollViewDidEndDecelerating`) or it simply stopped. An end faster
///   than `cutSpeed`, away from the content's ends, is a CUT, printed with
///   the stack that ended it when UIKit reports it;
/// - the page's own events that could stop it: page asks and landings
///   (insert or reload), the paging footer, the lead's height, every inset
///   write and offset write while a deceleration runs (with their stack).
@MainActor
final class ScrollStopTrace {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-scroll-stop-trace")

    /// The speed under which an end is a deceleration's natural rest.
    static let cutSpeed: CGFloat = 300

    private let origin = CACurrentMediaTime()
    private var lastTick: (time: CFTimeInterval, y: CGFloat)?
    private var speed: CGFloat = 0
    private var decelerating = false
    private var endReported = false
    private var link: CADisplayLink?
    private weak var scrollView: UIScrollView?

    private func stamp() -> String { String(format: "%7.0f", (CACurrentMediaTime() - origin) * 1000) }

    func event(_ text: String) {
        guard Self.isEnabled else { return }
        let y = scrollView.map { String(format: " y=%.0f", $0.contentOffset.y) } ?? ""
        print("[scroll-stop] \(stamp()) \(text)\(y)\(decelerating ? " DECEL" : "")")
    }

    /// An event that moves the scroll view, with who did it, when it lands
    /// mid-deceleration.
    func write(_ text: String) {
        guard Self.isEnabled else { return }
        event(text)
        if decelerating { printStack() }
    }

    func didScroll(_ scrollView: UIScrollView) {
        guard Self.isEnabled else { return }
        self.scrollView = scrollView
        let now = CACurrentMediaTime()
        let y = scrollView.contentOffset.y
        if let lastTick, now > lastTick.time {
            speed = (y - lastTick.y) / CGFloat(now - lastTick.time)
        }
        lastTick = (now, y)
    }

    func willEndDragging(velocity: CGPoint, target: CGFloat) {
        guard Self.isEnabled else { return }
        event(String(format: "release v=%.2f pt/ms target=%.0f", velocity.y, target))
    }

    func didEndDragging(decelerate: Bool, scrollView: UIScrollView) {
        guard Self.isEnabled, decelerate else { return }
        self.scrollView = scrollView
        decelerating = true
        endReported = false
        startWatching()
    }

    /// UIKit's own report of an end.
    func didEndDecelerating() {
        guard Self.isEnabled, decelerating else { return }
        endReported = true
        report(via: "didEndDecelerating")
        if isCut { printStack() }
        decelerating = false
        stopWatching()
    }

    private func report(via: String) {
        let kind = atContentEnd ? "rest at the content's end (bounce)" : isCut ? "⚠️ CUT" : "rest"
        event(String(format: "%@ END via %@, last speed %.0f pt/s", kind, via, speed))
    }

    /// Fast, and not at either end of the content: something stopped it.
    private var isCut: Bool { abs(speed) > Self.cutSpeed && !atContentEnd }

    /// Resting on the content's top or bottom: a bounce settles there with a
    /// spring's speed, which is no cut.
    private var atContentEnd: Bool {
        guard let scrollView else { return false }
        let inset = scrollView.adjustedContentInset
        let maxY = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let y = scrollView.contentOffset.y
        return abs(y - maxY) < 1 || abs(y + inset.top) < 1
    }

    private func printStack() {
        for line in Thread.callStackSymbols.dropFirst(2).prefix(22) {
            print("[scroll-stop]     \(line)")
        }
    }

    /// Every frame of a deceleration: an end UIKit did not report (the
    /// scroll view stopped without `scrollViewDidEndDecelerating`).
    private func startWatching() {
        stopWatching()
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopWatching() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame() {
        guard let scrollView, decelerating else { return stopWatching() }
        if !scrollView.isDecelerating, !endReported {
            report(via: "no callback (isDecelerating went false)")
            decelerating = false
            stopWatching()
        }
    }
}
#endif
