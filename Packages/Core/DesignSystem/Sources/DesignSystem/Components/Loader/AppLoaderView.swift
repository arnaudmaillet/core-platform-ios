import QuartzCore
import UIKit

/// The app's branded loader (#1329), replacing the stock spinner: the app
/// icon's four rounded pieces (the mark) that spin up and thin, over three
/// turns, into a turning ring while loading (#1744).
///
/// Its API mirrors `UIActivityIndicatorView` — `startAnimating()`,
/// `stopAnimating()`, `isAnimating`, `hidesWhenStopped`, a size — so a call site
/// migrates mechanically, plus `setProgress(_:)` for a pull to scrub it.
///
/// - **Pulled** (`setProgress`): the frame follows the finger exactly
///   (`AppLoaderTimeline.pull`); pulling back plays it in reverse.
/// - **Loading** (`startAnimating`): from wherever the pull left it — the rest
///   of the entry (`AppLoaderTimeline.entryRoute`), which a pull only ever
///   starts, then the loop, turning on at the same speed, with no jump.
/// - **Done** (`stopAnimating`): the mark fades where it is, still turning —
///   no closing back into the mark (the owner, 2026-10-17), so a short
///   load never plays more than it showed — the entry lasts ≈4.7 s, and many
///   loads end during it.
///
/// ⚠️ **CORE ANIMATION, NOT LOTTIE.** DesignSystem is under every package and
/// does not pull Lottie in, and CA animations run on the render server, so the
/// loader keeps turning while the main thread is busy loading.
///
/// ⚠️ **NO ANIMATION OFF-WINDOW (#580).** An endless animation recomposites
/// the frame; the loop is removed when the view leaves the window and put back
/// when it returns.
///
/// Reduce Motion, the app's switch or Power Saving (`MotionPreference`): no
/// morph and no turn — the static icon, fading in with the pull and pulsing
/// slowly while loading.
public final class AppLoaderView: UIView {
    public enum Size: Sendable {
        /// Paging footers, rows, buttons: `UIActivityIndicatorView.medium`'s 20pt.
        case medium
        /// Full-screen and pull-to-refresh: `.large`'s 37pt.
        case large

        public var side: CGFloat {
            switch self {
            case .medium: 20
            case .large: 37
            }
        }
    }

    /// Whether the loader is loading — set by `startAnimating`, cleared by
    /// `stopAnimating` (its exit still plays).
    public private(set) var isAnimating = false

    /// Hidden while neither loading, leaving, nor pulled — as the stock
    /// spinner. True by default, like it.
    public var hidesWhenStopped = true {
        didSet { updateVisibility() }
    }

    private let side: CGFloat
    private let mark = CALayer()
    private let pieces: [CAShapeLayer]
    private var progress: CGFloat = 0
    private var phase: Phase = .idle
    /// Bumped by every start and stop, so a completion from an older run
    /// cannot touch a newer one.
    private var generation = 0

    /// Swappable for tests; the app reads `MotionPreference`.
    var reducesMotion: () -> Bool = { MotionPreference.reducesMotion }

    private enum Phase: Equatable {
        case idle
        /// The icon appearing and thinning into the ring, from `from` seconds
        /// into the entry.
        case entering(begin: CFTimeInterval, from: TimeInterval, duration: CFTimeInterval)
        /// The ring turning, from `angle`.
        case looping(angle: CGFloat)
        case exiting
    }

    public convenience init(size: Size = .medium) {
        self.init(side: size.side)
    }

    public init(side: CGFloat) {
        self.side = side
        pieces = Palette.loaderTones.map { tone in
            let piece = CAShapeLayer()
            piece.fillColor = tone.cgColor
            return piece
        }
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Loading"
        layer.addSublayer(mark)
        pieces.forEach(mark.addSublayer)
        apply(AppLoaderTimeline.pull(0))
        updateVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        mark.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for piece in pieces { piece.frame = mark.bounds }
        CATransaction.commit()
    }

    // MARK: - The pull

    /// Scrubs the entry: `progress` is overscroll ÷ threshold, clamped to 0…1.
    /// Ignored while loading or leaving — the finger no longer drives it then.
    public func setProgress(_ progress: CGFloat) {
        self.progress = min(1, max(0, progress))
        guard !isAnimating, phase == .idle else { return }
        if reducesMotion() {
            applyStill(opacity: self.progress)
        } else {
            apply(AppLoaderTimeline.pull(self.progress))
        }
        updateVisibility()
    }

    // MARK: - Loading

    public func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        generation += 1
        removeAllAnimations()
        updateVisibility()
        if reducesMotion() {
            applyStill(opacity: 1)
            phase = .looping(angle: 0)
            if window != nil { addPulse() }
            return
        }
        guard window != nil else {
            // Off-window, the loop waits for the window (`didMoveToWindow`),
            // on the ring the entry lands on.
            apply(AppLoaderTimeline.entry(at: AppLoaderTimeline.entryDuration))
            phase = .looping(angle: AppLoaderTimeline.landingRotation)
            return
        }
        // Even a full pull has only started the entry: the rest plays from
        // the frame it reached.
        enter(from: AppLoaderTimeline.pullTime(progress))
    }

    /// Stops at once, with no fade of its own — for a host that has already
    /// taken the loader off screen (scaled it out, faded it): the loader's own
    /// fade, still running when the host put its alpha back, drew it again over
    /// what replaced it (the message time, filmed 2026-10-17).
    public func stopAnimating(animated: Bool) {
        guard animated else {
            guard isAnimating || phase != .idle else { return }
            isAnimating = false
            generation += 1
            finishExit()
            return
        }
        stopAnimating()
    }

    public func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        generation += 1
        let run = generation
        guard window != nil else { return finishExit() }
        // ⚠️ THE RING FADES WHERE IT IS, STILL TURNING (the owner, 2026-10-17,
        // on device). It used to close back into the square first — ≈0.9 s
        // that outlived the load: a refresh control had already folded away
        // and the square reappeared at the top of the list, and a load that
        // ended during the entry showed the whole ring before fading. Nothing
        // is removed here: whatever runs — the loop, or the entry still on its
        // way — carries on under the fade.
        phase = .exiting
        fadeOut(run: run)
    }

    // MARK: - Window

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // #580: nothing turns where nobody can see it.
            if phase == .exiting { return finishExit() }
            if case .entering = phase { phase = .looping(angle: AppLoaderTimeline.landingRotation) }
            removeAllAnimations()
            return
        }
        guard isAnimating, case let .looping(angle) = phase else { return }
        if reducesMotion() {
            addPulse()
        } else {
            apply(AppLoaderTimeline.Frame(
                outlines: (0..<AppLoaderGeometry.pieceCount).map(AppLoaderGeometry.restingRing),
                opacities: [1, 1, 1, 1], rotation: angle
            ))
            beginLoop(at: angle)
        }
    }

    // MARK: - Animations

    private static let loopKeyframes = AppLoaderTimeline.loopKeyframes()
    /// The whole entry, without a pull — most loaders play it.
    private static let fullEntry = AppLoaderTimeline.entryRoute(from: 0)
    /// Its paths per side, `[piece][keyframe]`, shared by every loader of that
    /// side: ≈140 keyframes × 4 pieces would be a megabyte per loader.
    private static var fullEntryShapes: [CGFloat: [[CGPath]]] = [:]

    /// The rest of the entry, from `start` seconds in to the ring, at the
    /// entry's own pace, then the loop.
    private func enter(from start: TimeInterval) {
        let duration = AppLoaderTimeline.entryDuration - start
        let route: [AppLoaderTimeline.Frame]
        let routeShapes: [[CGPath]]
        if start == 0 {
            route = Self.fullEntry
            if let shared = Self.fullEntryShapes[side] {
                routeShapes = shared
            } else {
                routeShapes = shapes(of: route)
                Self.fullEntryShapes[side] = routeShapes
            }
        } else {
            route = AppLoaderTimeline.entryRoute(from: start)
            routeShapes = shapes(of: route)
        }
        let run = generation
        phase = .entering(begin: CACurrentMediaTime(), from: start, duration: duration)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, generation == run, isAnimating, window != nil else { return }
            beginLoop(at: AppLoaderTimeline.landingRotation)
        }
        play(route, shapes: routeShapes, duration: duration, timing: .linear)
        CATransaction.commit()
    }

    /// The ring turning and its arcs trading length, forever, from `angle`.
    private func beginLoop(at angle: CGFloat) {
        phase = .looping(angle: angle)
        for (index, piece) in pieces.enumerated() {
            let shapes = CAKeyframeAnimation(keyPath: "path")
            shapes.values = Self.loopKeyframes[index].map(path)
            shapes.duration = AppLoaderTimeline.loopDuration
            shapes.repeatCount = .infinity
            shapes.calculationMode = .linear
            piece.add(shapes, forKey: Self.loopKey)
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = angle
        spin.toValue = angle + 2 * .pi * CGFloat(AppLoaderTimeline.turnsPerLoop)
        spin.duration = AppLoaderTimeline.loopDuration
        spin.repeatCount = .infinity
        mark.add(spin, forKey: Self.loopKey)
    }

    /// Keyframes through `route` — its outlines already made `shapes`,
    /// `[piece][keyframe]` — over `duration`; the model left on its last.
    private func play(
        _ route: [AppLoaderTimeline.Frame], shapes routeShapes: [[CGPath]],
        duration: CFTimeInterval, timing: CAMediaTimingFunctionName
    ) {
        guard let last = route.last else { return }
        for (index, piece) in pieces.enumerated() {
            let shapes = CAKeyframeAnimation(keyPath: "path")
            shapes.values = routeShapes[index]
            let fades = CAKeyframeAnimation(keyPath: "opacity")
            fades.values = route.map { Float($0.opacities[index]) }
            for animation in [shapes, fades] {
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: timing)
                piece.add(animation, forKey: animation.keyPath)
            }
        }
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = route.map(\.rotation)
        turn.duration = duration
        turn.timingFunction = CAMediaTimingFunction(name: timing)
        mark.add(turn, forKey: turn.keyPath)
        apply(last)
    }

    /// The mark fades and shrinks a little — over whatever is still running —
    /// then rests hidden.
    private func fadeOut(run: Int) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, generation == run else { return }
            finishExit()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = mark.opacity
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = AppLoaderTimeline.exitScale
        for animation in [fade, shrink] {
            animation.duration = AppLoaderTimeline.exitFadeDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            mark.add(animation, forKey: animation.keyPath)
        }
        CATransaction.commit()
    }

    /// Back to rest: the pull at zero, nothing running.
    private func finishExit() {
        removeAllAnimations()
        phase = .idle
        progress = 0
        mark.opacity = 1
        if reducesMotion() { applyStill(opacity: 0) } else { apply(AppLoaderTimeline.pull(0)) }
        updateVisibility()
    }

    /// Reduced motion while loading: the icon breathing slowly.
    private func addPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        mark.add(pulse, forKey: Self.loopKey)
    }

    private func removeAllAnimations() {
        mark.removeAllAnimations()
        pieces.forEach { $0.removeAllAnimations() }
    }

    private static let loopKey = "appLoader.loop"

    // MARK: - Frames

    /// Sets the model to `frame`, with no implicit animation.
    private func apply(_ frame: AppLoaderTimeline.Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, piece) in pieces.enumerated() {
            piece.path = path(frame.outlines[index])
            piece.opacity = Float(frame.opacities[index])
        }
        mark.transform = CATransform3DMakeRotation(frame.rotation, 0, 0, 1)
        CATransaction.commit()
    }

    /// Reduced motion: the icon, as on the app icon, at `opacity`.
    private func applyStill(opacity: CGFloat) {
        apply(AppLoaderTimeline.Frame(
            outlines: (0..<AppLoaderGeometry.pieceCount).map(AppLoaderGeometry.icon),
            opacities: Array(repeating: opacity, count: AppLoaderGeometry.pieceCount),
            rotation: 0
        ))
    }

    /// `route`'s outlines as paths, `[piece][keyframe]`.
    private func shapes(of route: [AppLoaderTimeline.Frame]) -> [[CGPath]] {
        (0..<AppLoaderGeometry.pieceCount).map { index in route.map { path($0.outlines[index]) } }
    }

    private func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x * side, y: $0.y * side) })
        path.closeSubpath()
        return path
    }

    private func updateVisibility() {
        isHidden = hidesWhenStopped && !isAnimating && phase == .idle && progress == 0
    }

    #if DEBUG
    /// What a test reads.
    var debugIsLooping: Bool { if case .looping = phase { return true } else { return false } }
    var debugIsEntering: Bool { if case .entering = phase { return true } else { return false } }
    var debugIsExiting: Bool { phase == .exiting }
    var debugAnimationCount: Int {
        (mark.animationKeys()?.count ?? 0) + pieces.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
    }
    var debugModelFrame: AppLoaderTimeline.Frame {
        AppLoaderTimeline.Frame(
            outlines: pieces.map { ($0.path?.loaderPoints ?? []).map { CGPoint(x: $0.x / side, y: $0.y / side) } },
            opacities: pieces.map { CGFloat($0.opacity) },
            rotation: (mark.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        )
    }
    #endif
}

private extension CGPath {
    /// The polygon's points, in order — every loader path is one.
    var loaderPoints: [CGPoint] {
        var points: [CGPoint] = []
        applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
            default: break
            }
        }
        return points
    }
}
