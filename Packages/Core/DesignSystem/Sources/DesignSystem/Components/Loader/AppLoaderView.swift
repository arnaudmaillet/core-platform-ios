import QuartzCore
import UIKit

/// The app's branded loader (#1329, #1795), replacing the stock spinner: three
/// pills side by side, each a dot at rest that grows into a taller pill and
/// back, rippling left to right as a continuous wave — never stopping — each
/// with a pale lead running just ahead of it.
///
/// Its API mirrors `UIActivityIndicatorView` — `startAnimating()`,
/// `stopAnimating()`, `isAnimating`, `hidesWhenStopped`, a size — so a call site
/// migrates mechanically, plus `setProgress(_:)` for a pull to scrub it.
///
/// - **Pulled** (`setProgress`): the wave follows the finger exactly
///   (`AppLoaderTimeline.pull`), at most one cycle; pulling back plays it in
///   reverse. Progress 0 is three dots.
/// - **Loading** (`startAnimating`): the same wave runs on from the time the
///   pull reached, forever, with no jump.
/// - **Done** (`stopAnimating`): the pills fade and shrink a little where
///   they are (the owner, 2026-10-17: no closing back).
///
/// ⚠️ **CORE ANIMATION, NOT LOTTIE.** DesignSystem is under every package and
/// does not pull Lottie in, and CA animations run on the render server, so the
/// loader keeps moving while the main thread is busy loading.
///
/// ⚠️ **NO ANIMATION OFF-WINDOW (#580).** An endless animation recomposites
/// the frame; the loop is removed when the view leaves the window and put back
/// when it returns, at the point of the wave it would have reached.
///
/// Reduce Motion, the app's switch or Low Power Mode (`MotionPreference`): no
/// wave — three dots, fading in with the pull and pulsing slowly while loading.
///
/// ⚠️ **ONE GRADIENT, MASKED BY THE PILLS (#2147, the owner 2026-11-05).** The
/// app icon's gradient, raspberry → violet → mint at the icon's opacities,
/// spans the whole mark; the pills are its mask, so a pill growing in the
/// wave shows more of it along its height, as a cut through the logo would.
/// The leads mask the same gradient at a lower opacity. It replaced one solid
/// colour per pill (#2083), too loud.
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
    /// The gradient the pills show, and the one under it the leads show.
    private let pillGradient = CAGradientLayer()
    private let leadGradient = CAGradientLayer()
    /// The pills, left to right, as `pillGradient`'s mask; the leads as
    /// `leadGradient`'s. Opaque shapes: their alpha is the mask's.
    private let pillMask = CALayer()
    private let leadMask = CALayer()
    private let pills: [CALayer]
    private let leads: [CALayer]
    private var progress: CGFloat = 0
    private var phase: Phase = .idle
    /// Bumped by every start and stop, so a completion from an older run
    /// cannot touch a newer one.
    private var generation = 0

    /// Swappable for tests; the app reads `MotionPreference`.
    var reducesMotion: () -> Bool = { MotionPreference.reducesMotion }

    private enum Phase: Equatable {
        case idle
        /// The wave running; `origin` is the media time its `t = 0` stands at.
        case looping(origin: CFTimeInterval)
        case exiting
    }

    public convenience init(size: Size = .medium) {
        self.init(side: size.side)
    }

    public init(side: CGFloat) {
        self.side = side
        pills = (0..<AppLoaderGeometry.pillCount).map { _ in CALayer() }
        leads = (0..<AppLoaderGeometry.pillCount).map { _ in CALayer() }
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Loading"
        layer.addSublayer(mark)
        let width = AppLoaderGeometry.pillWidth(side: side)
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        for (gradient, mask, pieces) in [(leadGradient, leadMask, leads), (pillGradient, pillMask, pills)] {
            gradient.frame = box
            gradient.startPoint = Palette.loaderGradientStart
            gradient.endPoint = Palette.loaderGradientEnd
            gradient.locations = Palette.loaderGradientLocations
            mask.frame = box
            for piece in pieces {
                piece.backgroundColor = UIColor.black.cgColor
                piece.cornerRadius = width / 2
                piece.cornerCurve = .circular
                mask.addSublayer(piece)
            }
            gradient.mask = mask
            mark.addSublayer(gradient)
        }
        leadGradient.opacity = Palette.loaderLeadOpacity
        applyTones()
        registerForTraitChanges([UITraitAccessibilityContrast.self]) { (self: Self, _: UITraitCollection) in
            self.applyTones()
        }
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
        CATransaction.commit()
    }

    /// The gradient's stops: the icon's, or opaque with Increased Contrast.
    private func applyTones() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let colors = Palette.loaderGradient(highContrast: traitCollection.accessibilityContrast == .high).map(\.cgColor)
        pillGradient.colors = colors
        leadGradient.colors = colors
        CATransaction.commit()
    }

    // MARK: - The pull

    /// Scrubs the wave: `progress` is overscroll ÷ threshold, clamped to 0…1.
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
        // The wave runs on from the time the pull reached: the same function,
        // so the release never jumps.
        let origin = CACurrentMediaTime() - AppLoaderTimeline.pullTime(progress)
        phase = .looping(origin: origin)
        if reducesMotion() {
            applyStill(opacity: 1)
            if window != nil { addPulse() }
            return
        }
        // Off-window, the loop waits for the window (`didMoveToWindow`).
        if window != nil { beginLoop(origin: origin) }
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
        // ⚠️ THE PILLS FADE WHERE THEY ARE, STILL MOVING (the owner,
        // 2026-10-17, on device): nothing is removed here — the wave carries
        // on under the fade.
        phase = .exiting
        fadeOut(run: run)
    }

    // MARK: - Window

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // #580: nothing moves where nobody can see it.
            if phase == .exiting { return finishExit() }
            removeAllAnimations()
            return
        }
        guard isAnimating, case let .looping(origin) = phase else { return }
        if reducesMotion() {
            addPulse()
        } else {
            beginLoop(origin: origin)
        }
    }

    // MARK: - Animations

    /// The keyframes of one cycle, shared by every loader.
    private static let cycle = AppLoaderTimeline.cycleSamples()

    /// The wave, forever: each pill and lead runs the same cycle, at the
    /// point of it `t` stands at now — `t` counted from `origin`. One whose
    /// own time has not started yet holds its dot until it does.
    private func beginLoop(origin: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let time = now - origin
        for index in 0..<AppLoaderGeometry.pillCount {
            for (piece, lead) in [(pills[index], false), (leads[index], true)] {
                let own = AppLoaderTimeline.cycleTime(pill: index, at: time, lead: lead)
                let grow = CAKeyframeAnimation(keyPath: "bounds.size.height")
                grow.values = Self.cycle.map { AppLoaderGeometry.pillHeight($0, side: side) }
                grow.duration = AppLoaderTimeline.period
                grow.repeatCount = .infinity
                grow.calculationMode = .linear
                if own < 0 {
                    // Still a dot: starts its cycle when its time comes.
                    grow.beginTime = layer.convertTime(now - own, from: nil)
                    grow.fillMode = .backwards
                } else {
                    grow.timeOffset = own
                }
                piece.add(grow, forKey: Self.loopKey)
            }
        }
        // The model as the wave stands now, under the animation.
        apply(AppLoaderTimeline.frame(at: time))
    }

    /// The pills fade and shrink a little — over the wave still running —
    /// then rest hidden.
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

    /// Reduced motion while loading: the dots breathing slowly.
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
        (pills + leads).forEach { $0.removeAllAnimations() }
    }

    private static let loopKey = "appLoader.loop"

    // MARK: - Frames

    /// Sets the model to `frame`, with no implicit animation.
    private func apply(_ frame: AppLoaderTimeline.Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<AppLoaderGeometry.pillCount {
            pills[index].frame = AppLoaderGeometry.pillFrame(index, height: frame.heights[index], side: side)
            leads[index].frame = AppLoaderGeometry.pillFrame(index, height: frame.leadHeights[index], side: side)
        }
        mark.opacity = 1
        CATransaction.commit()
    }

    /// Reduced motion: three dots at `opacity`.
    private func applyStill(opacity: CGFloat) {
        apply(AppLoaderTimeline.pull(0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.opacity = Float(opacity)
        CATransaction.commit()
    }

    private func updateVisibility() {
        isHidden = hidesWhenStopped && !isAnimating && phase == .idle && progress == 0
    }

    /// The loader as it shows now — its pills where the wave has them, in
    /// their gradient — drawn by hand on a margin `pad` wide: a toast blurs
    /// it from this (#2285, `ToastPictured`). Inside the toast's glass a
    /// layer mask isn't drawn, so a render of the masked gradient would not
    /// be what shows.
    func picture(scale: CGFloat, pad: CGFloat) -> CGImage? {
        let origin = CGPoint(x: pad + (bounds.width - side) / 2, y: pad + (bounds.height - side) / 2)
        let shownMark = mark.presentation() ?? mark
        let layers: [(CAGradientLayer, [CALayer])] = [(leadGradient, leads), (pillGradient, pills)]
        return ToastBlur.draw(size: bounds.size, pad: pad, scale: scale) { _ in
            guard let context = UIGraphicsGetCurrentContext() else { return }
            for (gradientLayer, pieces) in layers {
                let colours = (gradientLayer.colors ?? []) as CFArray
                let locations = (gradientLayer.locations ?? []).map { CGFloat($0.doubleValue) }
                guard let gradient = CGGradient(
                    colorsSpace: nil, colors: colours, locations: locations.isEmpty ? nil : locations
                ) else { continue }
                let path = UIBezierPath()
                for piece in pieces {
                    let frame = (piece.presentation() ?? piece).frame.offsetBy(dx: origin.x, dy: origin.y)
                    path.append(UIBezierPath(roundedRect: frame, cornerRadius: min(frame.width, frame.height) / 2))
                }
                context.saveGState()
                context.setAlpha(CGFloat(shownMark.opacity * gradientLayer.opacity))
                path.addClip()
                let start = gradientLayer.startPoint
                let end = gradientLayer.endPoint
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: origin.x + start.x * side, y: origin.y + start.y * side),
                    end: CGPoint(x: origin.x + end.x * side, y: origin.y + end.y * side),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                context.restoreGState()
            }
        }
    }

    #if DEBUG
    /// What a test reads.
    var debugIsLooping: Bool { if case .looping = phase { return true } else { return false } }
    var debugIsExiting: Bool { phase == .exiting }
    var debugAnimationCount: Int {
        (mark.animationKeys()?.count ?? 0) + (pills + leads).reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
    }
    /// The model's heights, 0 (a dot) … 1 (the peak).
    var debugModelFrame: AppLoaderTimeline.Frame {
        let width = AppLoaderGeometry.pillWidth(side: side)
        func fraction(_ piece: CALayer) -> CGFloat {
            (piece.bounds.height / width - 1) / (AppLoaderGeometry.peakRatio - 1)
        }
        return AppLoaderTimeline.Frame(heights: pills.map(fraction), leadHeights: leads.map(fraction))
    }
    var debugOpacity: Float { mark.opacity }
    /// The gradient the pills show and the one the leads show, and their
    /// masks: what a test reads of the look.
    var debugPillGradient: CAGradientLayer { pillGradient }
    var debugLeadGradient: CAGradientLayer { leadGradient }
    var debugPillsMaskTheGradient: Bool { pillGradient.mask === pillMask && pills.allSatisfy { $0.superlayer === pillMask } }
    var debugLeadsMaskTheGradient: Bool { leadGradient.mask === leadMask && leads.allSatisfy { $0.superlayer === leadMask } }
    #endif
}
