import QuartzCore
import UIKit

/// The give of a held window: while a grab carries the flight card, the card
/// stretches a little along the way it is being moved and thins a little
/// across it — the selector pill's give (`SelectorPillMotion`), on a window.
///
/// ⚠️ **ASKED FOR FROM A DEVICE (25 September 2026):** the grabbed window
/// "moved rawly, not organically", and the ask was the same slight dilation the
/// custom selector's pill has under a finger. Very light by construction: at
/// most `Tuning.maximumStretch` along the travel.
///
/// ⚠️ **ADDITIVE, IN THE RENDER TREE ONLY — NEVER THE MODEL.** The grab's
/// every other channel reads the card's MODEL geometry: the release settles
/// on its frame (`whenViewSettles`), the destination is told the card's rect
/// to draw beside it, the landing reads its bounds. A deformation written to
/// `transform` would change every one of those answers by a few percent. As a
/// held additive animation (concatenated onto the model's transform, the
/// scheme `PressFeedback` uses) it is drawn and nothing can read it.
///
/// ⚠️ **THE VELOCITY IS MEASURED HERE, FROM THE TRAVEL.** A pan's own
/// `velocity(in:)` is only available where the recogniser is; measuring from
/// the translations it is handed lets the scripted grab the simulator drives
/// (`debugPerformGrab`) wear the same give as a finger.
@MainActor
final class GrabDeformation {
    enum Tuning {
        /// Stretch per point/second of travel: 2000 pt/s — a brisk drag — is
        /// the cap.
        static let stretchPerSpeed: CGFloat = 1 / 80_000
        /// The most the card lengthens along its travel. A window is far
        /// larger than a pill, so its give is a third of the pill's 8%.
        static let maximumStretch: CGFloat = 0.025
        /// How much it thins across the travel, per unit of stretch.
        static let squashPerStretch: CGFloat = 0.5
        /// The measured speed is smoothed over this long…
        static let smoothing: CFTimeInterval = 0.06
        /// …and, once the travel stops arriving (a finger held still), eases
        /// to nothing over about this long.
        static let settle: CFTimeInterval = 0.1
        /// A travel older than this is a finger that has stopped.
        static let stillAfter: CFTimeInterval = 0.035
        /// The give let go on release.
        static let releaseDuration: CFTimeInterval = 0.22
    }

    private weak var layer: CALayer?
    private let reducesMotion: () -> Bool
    private var lastTranslation: CGPoint?
    private var lastSample: CFTimeInterval = 0
    /// What the travel says the speed is now, and the smoothed value drawn.
    private var measured: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private(set) var current: CATransform3D = CATransform3DIdentity

    private static let key = "coreNavigation.grabDeformation"

    init(layer: CALayer, reducesMotion: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled }) {
        self.layer = layer
        self.reducesMotion = reducesMotion
    }

    /// The grab's latest translation. Called on every pan event.
    func track(translation: CGPoint, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard !reducesMotion() else { return }
        if let last = lastTranslation, time > lastSample {
            let dt = CGFloat(max(time - lastSample, 1.0 / 240))
            measured = CGPoint(x: (translation.x - last.x) / dt, y: (translation.y - last.y) / dt)
        }
        lastTranslation = translation
        lastSample = time
        start()
    }

    /// The grab ended: the give eases out, and nothing is left on the layer.
    func release() {
        stop()
        guard let layer, layer.animation(forKey: Self.key) != nil else { return }
        let from = current
        layer.removeAnimation(forKey: Self.key)
        current = CATransform3DIdentity
        let ease = CABasicAnimation(keyPath: "transform")
        ease.isAdditive = true
        ease.fromValue = NSValue(caTransform3D: from)
        ease.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        ease.duration = Tuning.releaseDuration
        ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(ease, forKey: nil)
    }

    /// Drops the give at once — a teardown, not a release.
    func cancel() {
        stop()
        layer?.removeAnimation(forKey: Self.key)
        current = CATransform3DIdentity
    }

    // MARK: - The curve

    /// The deformation for a velocity: stretched by its speed along its
    /// direction, thinned across it — `R(θ) · S(1+s, 1−k·s) · R(−θ)`, so a
    /// diagonal drag pulls the card diagonally.
    nonisolated static func deformation(for velocity: CGPoint) -> CATransform3D {
        let speed = hypot(velocity.x, velocity.y)
        let stretch = min(Tuning.maximumStretch, speed * Tuning.stretchPerSpeed)
        guard stretch > 0.0005 else { return CATransform3DIdentity }
        let angle = atan2(velocity.y, velocity.x)
        let along = 1 + stretch
        let across = 1 - stretch * Tuning.squashPerStretch
        // Core Animation concatenates in row-vector order (`a` then `b`):
        // turn the travel onto x, scale, turn it back.
        let toAxis = CATransform3DMakeRotation(-angle, 0, 0, 1)
        let scale = CATransform3DMakeScale(along, across, 1)
        let back = CATransform3DMakeRotation(angle, 0, 0, 1)
        return CATransform3DConcat(CATransform3DConcat(toAxis, scale), back)
    }

    // MARK: - The clock

    private func start() {
        guard link == nil else { return }
        // The link retains its target until `stop()` invalidates it — which
        // every end of a grab calls (`release`, `cancel`).
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = CACurrentMediaTime()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastTranslation = nil
        measured = .zero
        velocity = .zero
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(now - lastTick, 1.0 / 240)
        lastTick = now
        // A finger held still sends no travel: what it last said decays.
        if now - lastSample > Tuning.stillAfter {
            let decay = CGFloat(exp(-dt / Tuning.settle))
            measured = CGPoint(x: measured.x * decay, y: measured.y * decay)
        }
        let blend = CGFloat(min(1, dt / Tuning.smoothing))
        velocity = CGPoint(
            x: velocity.x + (measured.x - velocity.x) * blend,
            y: velocity.y + (measured.y - velocity.y) * blend
        )
        apply(Self.deformation(for: velocity))
    }

    private func apply(_ transform: CATransform3D) {
        current = transform
        guard let layer else { return }
        let hold = CABasicAnimation(keyPath: "transform")
        hold.isAdditive = true
        hold.fromValue = NSValue(caTransform3D: transform)
        hold.toValue = NSValue(caTransform3D: transform)
        hold.duration = 1
        hold.fillMode = .forwards
        hold.isRemovedOnCompletion = false
        layer.add(hold, forKey: Self.key)
    }

    #if DEBUG
    /// Whether the give is on the layer — the one piece of the drawing a test
    /// can ask for.
    var debugIsOnTheLayer: Bool { layer?.animation(forKey: Self.key) != nil }
    /// Advances the clock by hand, for a test host that never ticks.
    func debugTick() { tick() }
    #endif
}
