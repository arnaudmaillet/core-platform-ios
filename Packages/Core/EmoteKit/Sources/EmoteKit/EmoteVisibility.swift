import DesignSystem
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
    /// and inside the window — as the MODEL has it, or as the screen shows it
    /// while Core Animation moves or fades something on the way up.
    ///
    /// ⚠️ **THE MODEL IS NOT WHAT IS ON SCREEN WHILE A LAYER ANIMATES.** The
    /// feed's danmaku parks each bubble's model at its EXIT, off the band's
    /// left edge, and flies it across with a `position.x` animation; the
    /// subtitle pill parks its model opacity at 0 and is held visible by a
    /// filled opacity animation. A model-only test called both invisible for
    /// their whole life, so their emotes never played until a scrub wrote the
    /// presentation positions into the models (probed 27 September 2026:
    /// every bubble on the band `visible=false`, model x −76, presentation
    /// x 34…347). So when the model says no and a layer on the way up carries
    /// animations, the walk is repeated on the presentation values.
    ///
    /// Either answer is enough: a view fading IN (model 1, presentation 0) is
    /// about to be seen, and one flying OUT (model off, presentation on) is
    /// being seen. `isHidden` is never animated, so a hidden cell still gives
    /// its slots back.
    ///
    /// One walk up the hierarchy, converting the rect a level at a time — a
    /// few microseconds for a label twenty views deep; the second walk runs
    /// only for a label the model places off screen or under a transparent
    /// ancestor (never for a hidden one), and reads a presentation layer only
    /// where a layer animates.
    static func isEffectivelyVisible(_ view: UIView) -> Bool {
        verdict(for: view) == .visible
    }

    enum Verdict: Equatable {
        case visible
        case invisible
        /// Invisible as far as anyone can tell yet, but a layer on the way up
        /// carries an animation the render tree has not committed (no
        /// presentation layer): the next turn can say otherwise.
        case awaitingPresentation
    }

    static func verdict(for view: UIView) -> Verdict {
        guard let window = view.window else { return .invisible }
        let model = walk(from: view, to: window, presented: false)
        if model.visible { return .visible }
        guard !model.blockedByHidden else { return .invisible }
        let presented = walk(from: view, to: window, presented: true)
        if presented.visible { return .visible }
        return presented.uncommittedAnimation ? .awaitingPresentation : .invisible
    }

    private struct Walk {
        var visible = false
        /// Stopped at a hidden view: no presentation can change that.
        var blockedByHidden = false
        /// Some animating layer had no presentation layer yet.
        var uncommittedAnimation = false
    }

    /// `presented`: a layer that carries animations is read through its
    /// presentation layer (its opacity, its geometry in its parent, its
    /// bounds as a clip), every other one through its model. A layer's place
    /// in its parent depends on its own position, bounds, anchor and
    /// transform only, so each level can be read from whichever tree is
    /// current for it.
    private static func walk(from view: UIView, to window: UIWindow, presented: Bool) -> Walk {
        var result = Walk()
        var current = view
        var layer = source(of: current.layer, presented: presented, into: &result)
        var rect = layer.bounds
        while true {
            if current.isHidden {
                result.blockedByHidden = true
                return result
            }
            if CGFloat(layer.opacity) < alphaThreshold { return result }
            guard let parent = current.superview else { break }
            let parentLayer = source(of: parent.layer, presented: presented, into: &result)
            if presented {
                rect = Self.rect(rect, inSuperlayerOf: layer)
            } else {
                rect = current.convert(rect, to: parent)
            }
            if parent.clipsToBounds, !rect.intersects(parentLayer.bounds) { return result }
            current = parent
            layer = parentLayer
        }
        result.visible = current === window && rect.intersects(layer.bounds)
        return result
    }

    /// The layer to read a level from: the model, or — in a presented walk,
    /// for a layer that animates — its presentation, when it has one.
    private static func source(of layer: CALayer, presented: Bool, into result: inout Walk) -> CALayer {
        guard presented, let keys = layer.animationKeys(), !keys.isEmpty else { return layer }
        guard let presentation = layer.presentation() else {
            result.uncommittedAnimation = true
            return layer
        }
        return presentation
    }

    /// `rect`, in `layer`'s own coordinates, in its superlayer's — from the
    /// layer's position, bounds, anchor point and (affine part of its)
    /// transform: what `CALayer.convert(_:to:)` does for one level, without
    /// needing both layers to belong to the same tree.
    static func rect(_ rect: CGRect, inSuperlayerOf layer: CALayer) -> CGRect {
        let bounds = layer.bounds
        let anchor = layer.anchorPoint
        let position = layer.position
        var transform = CGAffineTransform(
            translationX: -(bounds.minX + anchor.x * bounds.width),
            y: -(bounds.minY + anchor.y * bounds.height)
        )
        if !CATransform3DIsIdentity(layer.transform) {
            transform = transform.concatenating(CATransform3DGetAffineTransform(layer.transform))
        }
        transform = transform.concatenating(CGAffineTransform(translationX: position.x, y: position.y))
        return rect.applying(transform)
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
///
/// ⚠️ **A TICK WALKS NOTHING WHILE THE APP RESTS.** The walk is cheap per
/// label and not per second: profiled at ~2.4% of the main thread's busy time
/// (#830), most ticks re-asking a question whose answer had not changed. Two
/// states make the answer moot:
/// - **Idle calm** (`IdleCalm`): nobody has touched the app, so nobody
///   scrolled anything, and every emote is a still that holds no playback
///   slot — there is nothing to give back. Resting and waking both reset every
///   label's players and lay it out again, which re-asks then.
/// - **The background**: the song keeps the process running behind the home
///   screen (`UIBackgroundModes: audio`), and the timer with it — four walks a
///   second per label for a screen nobody can see.
@MainActor
final class EmoteVisibilityMonitor {
    static let shared = EmoteVisibilityMonitor()

    /// How often labels are re-checked. A label that scrolls INTO view shows
    /// its glyph for at most this long before animating; one that leaves
    /// gives its slot back within it.
    static let interval: TimeInterval = 0.25

    private let labels = NSHashTable<EmoteLabel>.weakObjects()
    private var timer: Timer?
    private var lifecycleObservers: [any NSObjectProtocol] = []
    /// Between `didEnterBackground` and `willEnterForeground`.
    private var isInBackground = false

    /// Whether a tick should skip its walk. Swappable for tests, which must not
    /// flip the app-wide `IdleCalm` under suites running beside them.
    var isResting: () -> Bool = { IdleCalm.isCalm }

    var isRunning: Bool { timer != nil }
    var registeredCount: Int { labels.allObjects.count }
    /// Labels re-checked so far, across every tick — what a test counts to
    /// tell a tick that walked from one that did not.
    private(set) var walkedLabelCount = 0

    init() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidEnterBackground() }
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.appWillEnterForeground() }
            }
        ]
    }

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

    /// One pass over every registered label — none while the app rests.
    func tick() {
        let live = labels.allObjects
        guard !live.isEmpty else {
            stop()
            return
        }
        guard !isInBackground, !isResting() else { return }
        walkedLabelCount += live.count
        live.forEach { $0.reevaluateVisibility() }
    }

    func appDidEnterBackground() { isInBackground = true }

    /// Back in front: the next tick walks again, and asks afresh.
    func appWillEnterForeground() { isInBackground = false }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
