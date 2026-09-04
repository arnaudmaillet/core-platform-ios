#if DEBUG
import UIKit

// MARK: - Playback

/// The single owner of motion: one clock for every icon in the process.
///
/// ## The optimisation this whole instrument exists to test
///
/// The intuitive way to keep 128 icons from looking like a marching band is to
/// stagger their `beginTime`. That is the wrong answer, and it is wrong in a way
/// no frame-rate counter will show you.
///
/// Core Animation composites when something CHANGES. 128 icons at 12fps on
/// independent phases produce ~1536 change instants per second, scattered — so
/// roughly 25 of them land on EVERY 60Hz refresh, and the display is pinned at
/// 60Hz forever. Apple's own guidance (WWDC22, *Power down: Improve battery
/// consumption*) prices exactly this shape: one secondary animation at 60fps
/// forces the whole screen to 60fps, and halving it "could save up to 20% of the
/// battery drain".
///
/// The fix costs nothing: keep `beginTime` IDENTICAL for every icon and rotate
/// the `values` array instead. Marker *k* starts at frame *k % frameCount*, so
/// every icon shows a different frame — no marching band — but every icon
/// changes on the SAME 12Hz grid. 12 composites per second instead of 60.
///
/// The epoch is the app's own shipped idiom: `SkeletonBoneView` pins every bone
/// to a fixed epoch in the shared timebase for the same reason.
///
/// `.freeRunning` reinstates the staggered version so the two can be compared
/// on a device with Instruments. In-process instrumentation cannot tell them
/// apart — which is precisely why the comparison has to exist as a toggle.
@MainActor
enum IconPlayback {

    enum Mode {
        /// Shared clock, phase by array rotation. The recommendation.
        case quantised
        /// Staggered `beginTime`. The control case.
        case freeRunning
    }

    static let animationKey = "iconbench.play"

    /// One fixed instant in the shared timebase. Every icon in the process
    /// hangs off it, so they are coherent by construction rather than by
    /// agreement.
    static let epoch: CFTimeInterval = CACurrentMediaTime()

    static func install(_ atlas: IconAtlas, phase: Int, mode: Mode, on layer: CALayer) {
        layer.removeAnimation(forKey: animationKey)
        layer.contents = atlas.sheet.cgImage
        layer.contentsGravity = .resize
        layer.magnificationFilter = .trilinear
        layer.minificationFilter = .trilinear

        guard atlas.frameCount > 1 else {
            layer.contentsRect = atlas.frameRects[0]
            return
        }

        let rotation = ((phase % atlas.frameCount) + atlas.frameCount) % atlas.frameCount
        let animation = CAKeyframeAnimation(keyPath: "contentsRect")
        animation.calculationMode = .discrete
        animation.duration = atlas.loopDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false

        switch mode {
        case .quantised:
            // Phase by ROTATION, clock shared.
            animation.values = Array(atlas.frameRects[rotation...] + atlas.frameRects[..<rotation])
            animation.beginTime = epoch
        case .freeRunning:
            // Phase by TIME, on instants INCOMMENSURATE with the frame duration.
            //
            // This was `epoch - rotation * frameDuration`, which is a whole
            // number of frames — the same grid reached by a time offset instead
            // of an array rotation. The two modes then changed on identical
            // instants BY CONSTRUCTION, so the A/B could not differ and a null
            // result would have read as "the shared epoch buys nothing".
            // An irrational-ish fraction of the loop is what actually scatters
            // the change instants, which is the thing under test.
            let scatter = (Double(phase) * 0.6180339887).truncatingRemainder(dividingBy: 1)
            animation.values = atlas.frameRects
            animation.beginTime = epoch - scatter * atlas.loopDuration
        }

        // Tell Core Animation what this animation actually needs.
        //
        // WITHOUT THIS, nothing in the process ever declares the icons' modest
        // appetite, and the claim that 12fps content costs fewer whole-screen
        // composites than 60fps content is an assumption — Apple documents the
        // hint as the mechanism, and documents nowhere that the rate is inferred
        // from keyframe density or from `.discrete`.
        //
        // A RANGE, not a pin: `minimum` well below `maximum` is what lets the
        // panel fall toward its 10Hz floor on a map nobody is touching, which is
        // the actual battery win. `minimum == maximum` would forbid precisely
        // the idle state the low rate exists to reach.
        //
        // ⚠️ Apple's ProMotion note says this hint needs
        // `CADisableMinimumFrameDurationOnPhone` in Info.plist to take effect —
        // and that same key unlocks 120Hz for every OTHER animation in the app.
        // The key is deliberately NOT added here: that coupling is a
        // whole-app decision, and measuring the hint's effect with and without
        // it is one of the on-device tests this instrument exists to set up.
        let ceiling = Float(1.0 / atlas.frameDuration)
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(8, ceiling), maximum: ceiling, preferred: 0
        )

        // Resting frame, so a marker whose animation is later suppressed by the
        // motion policy still shows the icon rather than going blank. A marker
        // never goes blank — not while loading, not while paused, not ever.
        layer.contentsRect = animation.values?.first as? CGRect ?? atlas.frameRects[0]
        layer.add(animation, forKey: animationKey)
    }

    /// Freezes on the current frame instead of resetting to zero, so a marker
    /// promoted back into motion resumes rather than restarts.
    static func freeze(_ layer: CALayer) {
        guard let presentation = layer.presentation() else {
            layer.removeAnimation(forKey: animationKey)
            return
        }
        let held = presentation.contentsRect
        layer.removeAnimation(forKey: animationKey)
        layer.contentsRect = held
    }

    static func remove(from layer: CALayer) {
        layer.removeAnimation(forKey: animationKey)
        layer.contents = nil
    }

    /// The gates that do not exist anywhere in this app today.
    ///
    /// Verified by grep at the time of writing: `isReduceMotionEnabled` appears
    /// in exactly one file (`SnapCommentTickerView`), and
    /// `isLowPowerModeEnabled` and `thermalState` appear NOWHERE. A feature that
    /// animates 128 things continuously cannot be the one that keeps ignoring
    /// them — and WCAG 2.2.2 (Level A, carried into native apps by EN 301 549
    /// and the European Accessibility Act) requires a pause mechanism for
    /// content that animates automatically past five seconds.
    static var motionAllowed: Bool {
        !UIAccessibility.isReduceMotionEnabled
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }
}
#endif
