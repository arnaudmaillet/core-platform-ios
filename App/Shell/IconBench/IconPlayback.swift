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

    /// How a decomposed track is sampled — the choice a sprite sheet does not
    /// get to make.
    ///
    /// On a sheet, smoothness costs MEMORY: 60fps means 60 cells. Decomposed,
    /// the samples are keyframes of a curve, so the same choice costs nothing in
    /// bytes and everything in COMPOSITE RATE — which is a battery decision the
    /// product can take per surface rather than a bake decision the CDN takes
    /// once for everybody.
    enum Sampling: String, CaseIterable {
        /// The same quantised grid the sheet plays on. Identical motion, so the
        /// A/B against `.sheet` compares representations and not animations.
        case stepped
        /// Real interpolation between keyframes. Genuinely fluid, and the honest
        /// price is that every marker now changes on every display refresh.
        case continuous
    }

    /// The product's three states, and the reason it is three rather than two.
    ///
    /// A boolean "animate or not" throws away the middle, which is the state the
    /// device is in most often when it matters. Measured on the decomposed path
    /// at chat density (684 emotes, iPhone 17 Pro Max simulator):
    ///
    ///     15 fps -> 10.7% app CPU, 1.1 MB    60 fps -> 12.0% app CPU, 1.1 MB
    ///
    /// So the rate is nearly free in CPU and exactly free in memory, and
    /// `.reduced` exists for BATTERY alone: halving the change instants is the
    /// only lever that touches whole-screen composite rate, which Apple prices
    /// at up to 20% of drain (WWDC22, *Power down*). Nothing on this screen can
    /// see that cost, which is precisely why the state has to exist as a
    /// switchable policy rather than as a number someone picked.
    ///
    /// ⚠️ `.reduced` DECIMATES the keys rather than lowering
    /// `preferredFrameRateRange`. Lowering the hint asks politely and leaves the
    /// animation with the same number of change instants; dropping every other
    /// key halves them for real. The hint is a ceiling, not a throttle.
    enum MotionPolicy: String, CaseIterable {
        /// Normal use: the asset's own rate, up to 60.
        case full
        /// Low Power. Half the change instants, same memory, same picture.
        case reduced
        /// Reduce Motion, or serious thermal pressure. The icon is POSED and
        /// static — never blank. A marker never goes blank.
        case still

        /// How many keys to skip. `.still` never reaches playback.
        var stride: Int { self == .reduced ? 2 : 1 }
    }

    /// The policy the device is asking for right now.
    ///
    /// ⚠️ Read at INSTALL time, so it must be re-read when the device changes
    /// its mind. `NSProcessInfoPowerStateDidChange` and
    /// `reduceMotionStatusDidChangeNotification` are the two that fire; without
    /// observing them a field installed before the user enabled Low Power keeps
    /// animating at full rate for the rest of the session, which is the exact
    /// failure the setting exists to prevent.
    static var devicePolicy: MotionPolicy {
        if UIAccessibility.isReduceMotionEnabled { return .still }
        if ProcessInfo.processInfo.thermalState.rawValue
            >= ProcessInfo.ThermalState.serious.rawValue { return .still }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .reduced }
        return .full
    }

    /// Set by the instrument to force a state the simulator cannot produce —
    /// there is no way to switch on Low Power in a simulator.
    static var forcedPolicy: MotionPolicy?

    static var policy: MotionPolicy { forcedPolicy ?? devicePolicy }

    /// Fires when the device's answer changes. The caller re-installs.
    static func observePolicyChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> [any NSObjectProtocol] {
        let names: [Notification.Name] = [
            .NSProcessInfoPowerStateDidChange,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            ProcessInfo.thermalStateDidChangeNotification
        ]
        return names.map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { onChange() } }
        }
    }

    static let animationKey = "iconbench.play"
    static let scaleKey = "iconbench.play.scale"
    static let rotationKey = "iconbench.play.rotation"
    static let alphaKey = "iconbench.play.alpha"
    static let decomposedKeys = [scaleKey, rotationKey, alphaKey]

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

        let rotation = ((phase % atlas.frameCount) + atlas.frameCount) % atlas.frameCount

        guard atlas.frameCount > 1, policy != .still else {
            // Posed, not blank, and posed at THIS marker's phase so a field
            // frozen by the policy still looks like a field rather than 128
            // copies of frame zero.
            layer.contentsRect = atlas.frameRects[rotation]
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "contentsRect")
        animation.calculationMode = .discrete
        animation.duration = atlas.loopDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false

        switch mode {
        case .quantised:
            // Phase by ROTATION, clock shared.
            let rotated = Array(atlas.frameRects[rotation...] + atlas.frameRects[..<rotation])
            animation.values = Self.decimated(rotated)
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
            animation.values = Self.decimated(atlas.frameRects)
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
        let ceiling = Float(1.0 / (atlas.frameDuration * Double(policy.stride)))
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(8, ceiling), maximum: ceiling, preferred: 0
        )

        // Resting frame, so a marker whose animation is later suppressed by the
        // motion policy still shows the icon rather than going blank. A marker
        // never goes blank — not while loading, not while paused, not ever.
        layer.contentsRect = animation.values?.first as? CGRect ?? atlas.frameRects[0]
        layer.add(animation, forKey: animationKey)
    }

    /// Keeps every `stride`-th value. The loop DURATION is unchanged, so the
    /// icon runs at the same speed with half the change instants — not at half
    /// speed, which is the mistake this exists to avoid.
    static func decimated<T>(_ values: [T]) -> [T] {
        let stride = policy.stride
        guard stride > 1, values.count > stride else { return values }
        return values.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
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

    // MARK: - The decomposed path

    /// Installs the same motion as three (usually one) property animations on a
    /// glyph that never leaves memory more than once.
    ///
    /// The plate is set here rather than baked: a `backgroundColor` and a
    /// circular `cornerRadius` cost zero bytes of backing store, where the
    /// sheet re-records the disc in full colour in all 24 cells.
    ///
    /// ⚠️ `.circular`, not `.continuous`. At radius = half the side a continuous
    /// curve is a superellipse, not a circle — a subtly squarish plate that no
    /// number on this screen would ever flag.
    static func install(
        _ still: IconStill,
        phase: Int,
        mode: Mode,
        sampling: Sampling,
        plate: CALayer,
        glyph: CALayer
    ) {
        decomposedKeys.forEach { glyph.removeAnimation(forKey: $0) }

        plate.backgroundColor = still.plate.cgColor
        plate.cornerRadius = plate.bounds.width / 2
        plate.cornerCurve = .circular
        glyph.contents = still.glyph.cgImage
        glyph.contentsGravity = .resize
        glyph.magnificationFilter = .trilinear
        glyph.minificationFilter = .trilinear

        let track = still.track(phase: phase)

        // The resting pose, on the MODEL layer. A marker whose animation is
        // later suppressed by the motion policy — or stripped by a background
        // transition — must still show the icon, posed, rather than snapping to
        // identity. A marker never goes blank and never jumps.
        glyph.transform = CATransform3DConcat(
            CATransform3DMakeScale(track.scales[0], track.scales[0], 1),
            CATransform3DMakeRotation(track.rotations[0], 0, 0, 1)
        )
        glyph.opacity = Float(track.alphas[0])

        guard track.frameCount > 1, policy != .still else { return }

        // Only the channels that MOVE. `.spin` and `.pulse` install one
        // animation each; `.flicker` two. Installing three unconditionally would
        // put 384 animations on the render server where 154 will do, and would
        // make this path look more expensive than the sheet's single
        // `contentsRect` animation for no reason at all.
        if track.movesScale {
            glyph.add(animation(track.scales, track: track, mode: mode, sampling: sampling,
                                keyPath: "transform.scale", phase: phase), forKey: scaleKey)
        }
        if track.movesRotation {
            glyph.add(animation(track.rotations, track: track, mode: mode, sampling: sampling,
                                keyPath: "transform.rotation.z", phase: phase), forKey: rotationKey)
        }
        if track.movesAlpha {
            glyph.add(animation(track.alphas, track: track, mode: mode, sampling: sampling,
                                keyPath: "opacity", phase: phase), forKey: alphaKey)
        }
    }

    private static func animation(
        _ channel: [Double],
        track: IconMotionTrack,
        mode: Mode,
        sampling: Sampling,
        keyPath: String,
        phase: Int
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.duration = track.loopDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false

        switch sampling {
        case .stepped:
            // DROP the closing sample. `.discrete` divides the duration by
            // `values.count`, so keeping it would stretch the loop by one frame
            // and put this path on a different clock from the sheet's — which
            // would silently invalidate the very comparison the toggle exists
            // for.
            animation.calculationMode = .discrete
            animation.values = decimated(Array(channel.dropLast()))
        case .continuous:
            animation.calculationMode = .linear
            // Decimate the KEYS, then re-close the loop: dropping the closing
            // sample here would make `.linear` interpolate from the last key
            // back to the first over one key-interval instead of arriving on it.
            var keys = decimated(Array(channel.dropLast()))
            keys.append(channel[channel.count - 1])
            animation.values = keys
        }

        // The track is ALREADY phased by sampling from a rotated grid, exactly
        // as the sheet phases by rotating its `values`. So `beginTime` stays on
        // the shared epoch and every marker still changes on one clock.
        switch mode {
        case .quantised:
            animation.beginTime = epoch
        case .freeRunning:
            let scatter = (Double(phase) * 0.6180339887).truncatingRemainder(dividingBy: 1)
            animation.beginTime = epoch - scatter * track.loopDuration
        }

        switch sampling {
        case .stepped:
            // ⚠️ OBSERVED, and unresolved: with this range the render server
            // sometimes settles at ~16 Hz for a 30 Hz stepped track (measured
            // `presented_fps=15.8` on iPhone SE 3, 84 markers, and once on
            // 17 Pro Max at 128). That is the range being honoured, not a
            // defect — but on a `.discrete` animation a lower presented rate
            // means DROPPED STEPS, where on `.continuous` it would only mean
            // coarser interpolation. Whether a stepped track should therefore
            // declare `minimum == maximum` and give up the idle-down battery
            // win is a device question: it needs Instruments (Core Animation +
            // Energy) on hardware, not a decision taken from a simulator.
            let ceiling = Float(1.0 / (track.step * Double(policy.stride)))
            animation.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(8, ceiling), maximum: ceiling, preferred: 0
            )
        case .continuous:
            // No ceiling to declare: an interpolated curve genuinely changes on
            // every refresh. Asking for less would quantise it back into the
            // stepped case while still paying for the extra keyframes.
            let panel = Float(UIScreen.main.maximumFramesPerSecond) / Float(policy.stride)
            animation.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(30, panel), maximum: panel, preferred: 0
            )
        }
        return animation
    }

    static func freezeDecomposed(glyph: CALayer) {
        guard let presentation = glyph.presentation() else {
            decomposedKeys.forEach { glyph.removeAnimation(forKey: $0) }
            return
        }
        let transform = presentation.transform
        let opacity = presentation.opacity
        decomposedKeys.forEach { glyph.removeAnimation(forKey: $0) }
        glyph.transform = transform
        glyph.opacity = opacity
    }

    static func removeDecomposed(plate: CALayer, glyph: CALayer) {
        decomposedKeys.forEach { glyph.removeAnimation(forKey: $0) }
        glyph.contents = nil
        glyph.transform = CATransform3DIdentity
        glyph.opacity = 1
        plate.backgroundColor = nil
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
    /// Kept as the coarse question some callers still ask. The nuance lives in
    /// `policy`: Low Power now HALVES the rate rather than stopping the icon,
    /// because a still icon is a worse answer than a slower one whenever the
    /// motion is what the icon means.
    static var motionAllowed: Bool { policy != .still }
}
#endif
