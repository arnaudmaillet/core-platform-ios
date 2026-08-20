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
/// Two consecutive frames that move the view less than a point, HAVING SEEN IT
/// MOVE AT ALL first. The "moved first" gate matters: the first tick can land
/// before the animation has committed, and an ungated check would call that
/// settled and retire the view immediately.
@MainActor
func whenViewSettles(
    _ view: UIView, ceiling: CFTimeInterval, then work: @escaping () -> Void
) {
    let watcher = ViewSettleWatcher(
        view: view, deadline: CACurrentMediaTime() + ceiling, work: work
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
    private var previous: CGRect?
    private var hasMoved = false
    private var stillFrames = 0
    /// Held by the watcher, which the display link retains — the pair keeps
    /// itself alive exactly as long as it is ticking.
    var link: CADisplayLink?

    init(view: UIView, deadline: CFTimeInterval, work: @escaping () -> Void) {
        self.view = view
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
        if delta > 1 { hasMoved = true; stillFrames = 0; return }
        guard hasMoved else { return }
        stillFrames += 1
        if stillFrames >= 2 { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        work()
    }
}
