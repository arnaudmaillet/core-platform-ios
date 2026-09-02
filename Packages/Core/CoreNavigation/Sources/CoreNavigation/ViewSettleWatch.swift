import UIKit

/// Runs `work` once `view` has stopped moving, whatever clock it is moving on.
///
/// ## Why not a timer
///
/// Teardown after a release has to follow the ANIMATION, not the wall clock.
/// This began life as a fixed `asyncAfter(springDuration + 0.04)`, on the sound
/// reasoning that `UIView` completion blocks inside an interactive navigation
/// transition's ambit can be deferred indefinitely — which is real, and is why
/// completion handlers are still not used for this.
///
/// But a delay and a spring are two clocks, and the simulator's Slow Animations
/// stretches only one of them. Measured: a card was retired 0.46s after release
/// with its presentation frame still at 688pt of 831 — barely a sixth of the
/// way home — so it vanished mid-flight and the landing tile appeared. That is
/// what reads as an instant teleport on release.
///
/// Nor can the factor be looked up: the simulator does not implement the
/// slowdown as a layer speed, and the window reports 1.0 either way (measured).
/// So this watches the PRESENTATION layer, which is on whatever clock the
/// animation is actually on, and keeps a wall-clock ceiling as the backstop the
/// old timer was.
///
/// ## What counts as settled
///
/// Two consecutive frames that move the view less than a point, once it is
/// WHERE IT IS GOING. Both halves are needed: an ungated stillness check would
/// fire on the first tick, before the animation has committed, and retire the
/// view immediately.
///
/// ⚠️ IT USED TO ASK "HAS IT MOVED AT ALL", and that is a different question
/// with a filmed answer. A release that barely moved — the ~10pt a pan needs to
/// begin, then a lift — springs a distance under the one-point threshold, so
/// the view never registers as having moved and the watch runs to its six
/// second ceiling: the page stays parented in the transition host, the source
/// stays concealed and the whole dismissal sits staged, for six seconds, after
/// an animation that finished in half of one.
///
/// Asking where it is instead answers both cases with one rule. A view already
/// at its target has settled by definition, however little it travelled to get
/// there; a view still short of it has not, however still this frame looked.
@MainActor
func whenViewSettles(
    _ view: UIView,
    settlingAt target: CGRect,
    ceiling: CFTimeInterval,
    then work: @escaping () -> Void
) {
    let watcher = ViewSettleWatcher(
        view: view, target: target,
        deadline: CACurrentMediaTime() + ceiling, work: work
    )
    let link = CADisplayLink(target: watcher, selector: #selector(ViewSettleWatcher.tick))
    link.add(to: .main, forMode: .common)
    watcher.link = link
}

/// The ceiling every release shares: long enough that Slow Animations cannot
/// trip it, short enough that a stalled animation still tears down.
let viewSettleCeiling: CFTimeInterval = 6

@MainActor
private final class ViewSettleWatcher: NSObject {
    private weak var view: UIView?
    private let deadline: CFTimeInterval
    private let work: () -> Void
    private let target: CGRect
    private var previous: CGRect?
    private var stillFrames = 0
    /// Held by the watcher, which the display link retains — the pair keeps
    /// itself alive exactly as long as it is ticking.
    var link: CADisplayLink?

    init(
        view: UIView, target: CGRect, deadline: CFTimeInterval,
        work: @escaping () -> Void
    ) {
        self.view = view
        self.target = target
        self.deadline = deadline
        self.work = work
    }

    @objc func tick() {
        guard let view, CACurrentMediaTime() < deadline else { return finish() }
        let frame = view.layer.presentation()?.frame ?? view.layer.frame
        defer { previous = frame }
        guard let previous else { return }
        let delta = max(abs(frame.origin.x - previous.origin.x),
                        abs(frame.origin.y - previous.origin.y),
                        abs(frame.width - previous.width),
                        abs(frame.height - previous.height))
        if delta > 1 { stillFrames = 0; return }
        // Still AND arrived. A frame that has stopped short of the target is
        // an animation that has not started yet, or one this watch must keep
        // waiting on.
        guard ViewSettleWatcher.isAt(target, frame) else { return }
        stillFrames += 1
        if stillFrames >= 2 { finish() }
    }

    /// Within a point on every edge — the same tolerance stillness is judged
    /// by, so a view cannot be "moving" and "arrived" at once.
    private static func isAt(_ target: CGRect, _ frame: CGRect) -> Bool {
        max(abs(frame.origin.x - target.origin.x),
            abs(frame.origin.y - target.origin.y),
            abs(frame.width - target.width),
            abs(frame.height - target.height)) <= 1
    }

    private func finish() {
        link?.invalidate()
        link = nil
        work()
    }
}
