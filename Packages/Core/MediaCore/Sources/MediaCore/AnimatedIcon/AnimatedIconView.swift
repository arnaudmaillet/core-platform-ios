import DesignSystem
import QuartzCore
import UIKit

/// Plays an `AnimatedIconArt`, filling its bounds.
///
/// A view rather than a pile of layer code at the call site, because the map
/// draws the same icon in three places — the pin, the cluster and the hero
/// flight card — and three surfaces agreeing on layer choreography is three
/// chances to drift.
///
/// ## What it costs
///
/// Nothing per frame. The animation is a `CAKeyframeAnimation` run by the
/// render server, out of process: the app's main thread never wakes for it, and
/// the icons keep moving through a main-thread stall. Measured on the map's
/// worst case — 128 markers on the saturated 64pt lattice — app CPU 6%, zero
/// hitches, and the frame rate is free: 15 fps and 60 fps differ by 1.3 points
/// of CPU and by no memory at all.
///
/// ## No circle
///
/// Unlike an avatar, an icon is NOT clipped to a disc: the artwork owns the
/// whole box, alpha included. That is a product decision and it also removes
/// the most expensive thing this feature could have done — a mask on a layer
/// whose contents change every frame costs an offscreen pass per marker per
/// frame, which at 128 markers is larger than everything else combined.
@MainActor
public final class AnimatedIconView: UIView {

    /// The device's three-state answer, and it is three rather than two because
    /// a boolean throws away the middle — the state the device is in most often
    /// when it matters.
    public enum MotionPolicy: String, Sendable, CaseIterable {
        /// Normal use: the asset's own rate.
        case full
        /// Low Power. Half the change instants, same memory, same picture.
        case reduced
        /// Reduce Motion, or serious thermal pressure. POSED and static —
        /// never blank, and posed at this marker's own phase so a frozen field
        /// still looks like a field rather than N copies of frame zero.
        case still

        var stride: Int { self == .reduced ? 2 : 1 }
    }

    public static var devicePolicy: MotionPolicy {
        if MotionPreference.reducesMotion { return .still }
        if ProcessInfo.processInfo.thermalState.rawValue
            >= ProcessInfo.ThermalState.serious.rawValue { return .still }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .reduced }
        return .full
    }

    /// Overrides the device's answer. Exists because no simulator can switch on
    /// Low Power, so without it two of the three states are untestable.
    public static var forcedPolicy: MotionPolicy?
    public static var policy: MotionPolicy { forcedPolicy ?? devicePolicy }

    /// Fires when the device changes its answer; the caller re-installs.
    ///
    /// ⚠️ The policy is read at INSTALL time, so this is not optional. Without
    /// it, a field dressed before the user enabled Low Power keeps animating at
    /// full rate for the rest of the session — the exact failure the setting
    /// exists to prevent. Nothing else in this app observed these until now.
    public static func observePolicyChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> [any NSObjectProtocol] {
        [
            Notification.Name.NSProcessInfoPowerStateDidChange,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            ProcessInfo.thermalStateDidChangeNotification
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
        }
    }

    private static let sheetKey = "animatedIcon.sheet"
    private static let scaleKey = "animatedIcon.scale"
    private static let rotationKey = "animatedIcon.rotation"
    private static let alphaKey = "animatedIcon.alpha"
    private static let markKeys = [scaleKey, rotationKey, alphaKey]

    /// One fixed instant every icon in the process hangs off, so they are
    /// coherent by construction rather than by agreement. The app's own idiom —
    /// `SkeletonBoneView` pins every bone to a fixed epoch for the same reason.
    private static let epoch: CFTimeInterval = CACurrentMediaTime()

    /// ⚠️ VIEWS, not bare layers positioned in `layoutSubviews`.
    ///
    /// The obvious implementation is two `CALayer`s re-framed on every layout
    /// pass, and on this map it is a bug: the hero flight animates the card's
    /// frame with NO layout pass inside its animation block, so the icon would
    /// sit at 44pt while the card filled the screen. That is the same defect
    /// `PinCardView.setZoomContentBlend` exists to work around for the
    /// departure cover. A subview's autoresizing mask is applied synchronously
    /// inside `setBounds`, so it tracks an animated frame for free.
    ///
    /// `CALayer.autoresizingMask` is not an answer — it is macOS-only.
    private let sheetView = UIView()
    private let markView = UIView()

    private var art: AnimatedIconArt?
    private var phase = 0

    /// What an ICON does with its face: fills it. An icon is authored for the
    /// marker it is drawn on, and its plate is square in a square face, so
    /// stretching and aspect-filling are the same operation.
    static let defaultContentGravity: CALayerContentsGravity = .resize

    /// How the artwork fits the view. `.resize` for a mark; a PHOTOGRAPHIC
    /// sheet needs `.resizeAspectFill`.
    ///
    /// ⚠️ A VIDEO PREVIEW IS NOT AN ICON. The cells of a preview sheet are
    /// frames of a film, and this view is full-bleed inside a card that travels
    /// from a 56pt square to a 402x874 page — so `.resize` stretched the picture
    /// to the card's aspect at every step. Filmed: the trunk of a tree thin and
    /// elongated through the whole present, against a settled page where it is
    /// not. It also broke the rung below it: the cover under the sheet is
    /// `.scaleAspectFill`, so the two layers of one picture disagreed.
    public var contentGravity: CALayerContentsGravity = AnimatedIconView.defaultContentGravity {
        didSet {
            sheetView.layer.contentsGravity = contentGravity
            markView.layer.contentsGravity = contentGravity
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false
        for view in [sheetView, markView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            view.isHidden = true
            view.layer.contentsGravity = Self.defaultContentGravity
            view.layer.contentsScale = UIScreen.main.scale
            view.layer.magnificationFilter = .trilinear
            view.layer.minificationFilter = .trilinear
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Dresses the view and starts playback. `nil` clears it.
    ///
    /// `phase` is a pure function of the marker's identity, so the hero flight
    /// card reproduces the exact frame by copying one `Int` — and so that a
    /// field of markers shows different frames without any of them leaving the
    /// shared clock.
    ///
    /// `paused` dresses it STILL on frame `phase`: `resume()` plays on from
    /// that frame.
    public func setArt(_ art: AnimatedIconArt?, phase: Int = 0, paused: Bool = false) {
        cancelFinish()
        self.art = art
        self.phase = phase
        clockShift = 0
        heldFrame = nil
        dress()
        if paused, let art {
            hold(((phase % art.frameCount) + art.frameCount) % art.frameCount)
        }
    }

    /// Re-installs after anything that strips animations — a foreground
    /// transition does, and so does a motion-policy change.
    ///
    /// ⚠️ Unconditional. A "reinstall only if not already running" guard can
    /// only ever PROMOTE a marker, never demote one, so it silently ignores
    /// every change into Low Power or Reduce Motion.
    ///
    /// A paused view stays paused, on the frame it holds.
    public func reinstall() {
        let held = heldFrame
        heldFrame = nil
        dress()
        if let held { hold(held) }
    }

    private func dress() {
        clearAnimations()
        guard let art else {
            sheetView.isHidden = true
            markView.isHidden = true
            return
        }
        switch art {
        case .sheet(let sheet):
            markView.isHidden = true
            sheetView.isHidden = false
            install(sheet)
        case .decomposed(let still):
            sheetView.isHidden = true
            markView.isHidden = false
            install(still)
        }
    }

    // MARK: - Pausing

    /// The frame a paused view holds; nil while it plays.
    private var heldFrame: Int?
    /// Every installed animation's `timeOffset`: zero on the shared clock,
    /// a whole number of keys once a resume has carried a frame over.
    private var clockShift: CFTimeInterval = 0

    /// Whether the view holds one frame instead of playing.
    public var isPaused: Bool { heldFrame != nil }

    /// Stops on the frame showing NOW; `resume()` plays on from that very
    /// frame — no jump back to the first, no flash.
    ///
    /// ⚠️ NOT BY STOPPING A LAYER CLOCK. The textbook pause (QA1673: `speed`
    /// 0 and `timeOffset` on an ancestor) froze this view's presentation
    /// layer in the app and NOT the screen: inside the Messages footer's
    /// glass bar the render server kept the icons looping (filmed,
    /// 2026-10-01, while `presentedTick` stood still). So a pause removes the
    /// animations and poses the MODEL on the frame — the one thing every
    /// renderer agrees on, and a paused icon costs nothing at all.
    public func pause() {
        cancelFinish()
        guard !isPaused, let frame = displayedFrame else { return }
        hold(frame)
    }

    // MARK: - Finishing the loop

    /// Bumped by every finish asked for and every cancel, so a stale
    /// deadline never holds a frame.
    private var finishGeneration = 0
    /// Whether the view is playing out its current loop before holding.
    public private(set) var isFinishingLoop = false
    /// The longest a finish waits for its loop to end. A long emote would
    /// otherwise keep its engine slot for seconds after the scroll stopped;
    /// past this it simply holds where it is, as a stop always did.
    public static let maxFinishWait: TimeInterval = 1.5

    /// How long until the loop on screen ends; nil when nothing plays.
    /// Keyed like `displayedFrame` (`keying`): a Low Power decimated loop
    /// keeps its duration, with fewer, longer keys.
    public var remainingLoopTime: TimeInterval? {
        guard let art, art.frameCount > 1, isAnimating, !isPaused else { return nil }
        let (_, keys, keyDuration) = Self.keying(art)
        let loop = keyDuration * CFTimeInterval(keys)
        var elapsed = (sheetView.layer.convertTime(CACurrentMediaTime(), from: nil) - Self.epoch + clockShift)
            .truncatingRemainder(dividingBy: loop)
        if elapsed < 0 { elapsed += loop }
        return loop - elapsed
    }

    /// Lets the loop on screen run to its end, then holds the RESTING frame —
    /// the one the art was dressed on (`phase`), which is where every loop
    /// starts again — and calls `completion` (#559). An emote never stops
    /// posed mid-gesture.
    ///
    /// `cancelFinish()`, `pause()` or new art before the end drop the finish:
    /// the loop simply plays on, with no restart and no jump. Nothing playing
    /// (paused, still art, motion off) completes at once.
    ///
    /// The deadline comes from the same clock `displayedFrame` reads, keyed
    /// the same way (`keying`), so a Low Power decimated loop ends where its
    /// last key does.
    public func finishLoop(completion: @escaping @MainActor () -> Void) {
        guard let remaining = remainingLoopTime else {
            completion()
            return
        }
        // A loop too long to wait for holds where it is, now.
        guard remaining <= Self.maxFinishWait else {
            pause()
            completion()
            return
        }
        finishGeneration += 1
        let generation = finishGeneration
        isFinishingLoop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.finishGeneration == generation, self.isFinishingLoop,
                      let art = self.art else { return }
                self.isFinishingLoop = false
                let count = art.frameCount
                self.hold(((self.phase % count) + count) % count)
                completion()
            }
        }
    }

    /// Keeps playing: a finish asked for is dropped, and the loop goes on
    /// from where it is.
    public func cancelFinish() {
        guard isFinishingLoop else { return }
        isFinishingLoop = false
        finishGeneration += 1
    }

    /// Plays on from the held frame. The animations go back on the shared
    /// clock's grid, shifted by whole keys, so the held frame is the one on
    /// screen until the grid's next change and the loop runs on from it.
    public func resume() {
        guard let frame = heldFrame, let art else { return }
        heldFrame = nil
        let count = art.frameCount
        let (step, keys, keyDuration) = Self.keying(art)
        let rotation = ((phase % count) + count) % count
        let key = ((frame - rotation + count) % count) / step
        let now = sheetView.layer.convertTime(CACurrentMediaTime(), from: nil) - Self.epoch
        let loop = keyDuration * CFTimeInterval(keys)
        var shift = (CFTimeInterval(key) - (now / keyDuration).rounded(.down)) * keyDuration
        shift = shift.truncatingRemainder(dividingBy: loop)
        if shift < 0 { shift += loop }
        clockShift = shift
        dress()
    }

    private func hold(_ frame: Int) {
        guard let art else { return }
        heldFrame = frame
        clearAnimations()
        switch art {
        case .sheet(let sheet):
            sheetView.layer.contentsRect = sheet.frameRects[frame]
        case .decomposed(let still):
            let track = still.track
            guard track.scales.indices.contains(frame) else { return }
            markView.layer.transform = CATransform3DConcat(
                CATransform3DMakeScale(track.scales[frame], track.scales[frame], 1),
                CATransform3DMakeRotation(track.rotations[frame], 0, 0, 1)
            )
            markView.layer.opacity = Float(track.alphas[frame])
        }
    }

    /// How the installed keys divide one loop: every `step`-th rotated frame,
    /// spread evenly (`decimated`, `.discrete`).
    private static func keying(_ art: AnimatedIconArt) -> (step: Int, keys: Int, keyDuration: CFTimeInterval) {
        let count = art.frameCount
        let stride = policy.stride
        let step = stride > 1 && count > stride ? stride : 1
        let keys = (count + step - 1) / step
        return (step, keys, art.frameDuration * CFTimeInterval(count) / CFTimeInterval(keys))
    }

    /// The art's frame on show: the held one, or the one the clock is on.
    /// Worked out from the clock rather than read off the render server, so
    /// it holds headless too. Nil without art.
    public var displayedFrame: Int? {
        guard let art else { return nil }
        if let heldFrame { return heldFrame }
        let count = art.frameCount
        let rotation = ((phase % count) + count) % count
        guard count > 1, isAnimating else { return rotation }
        let (step, keys, keyDuration) = Self.keying(art)
        let loop = keyDuration * CFTimeInterval(keys)
        var elapsed = (sheetView.layer.convertTime(CACurrentMediaTime(), from: nil) - Self.epoch + clockShift)
            .truncatingRemainder(dividingBy: loop)
        if elapsed < 0 { elapsed += loop }
        let key = min(keys - 1, Int(elapsed / keyDuration))
        return (rotation + key * step) % count
    }

    /// A fingerprint of what the render server is presenting right now, or nil
    /// when nothing is animating.
    ///
    /// It has to be a fingerprint rather than one property: the sheet path
    /// moves `contentsRect` and the decomposed path moves a transform, so
    /// probing either one alone would report the other as motionless — which
    /// reads exactly like a broken animation and would be believed.
    public var presentedTick: Double? {
        if sheetView.layer.animation(forKey: Self.sheetKey) != nil {
            guard let rect = sheetView.layer.presentation()?.contentsRect else { return nil }
            return Double(rect.origin.x) * 4096 + Double(rect.origin.y)
        }
        guard Self.markKeys.contains(where: { markView.layer.animation(forKey: $0) != nil }),
              let presentation = markView.layer.presentation() else { return nil }
        let transform = presentation.transform
        return Double(transform.m11) * 1e6 + Double(transform.m12) * 1e3
            + Double(presentation.opacity)
    }

    public var isAnimating: Bool {
        sheetView.layer.animation(forKey: Self.sheetKey) != nil
            || Self.markKeys.contains { markView.layer.animation(forKey: $0) != nil }
    }

    private func clearAnimations() {
        sheetView.layer.removeAnimation(forKey: Self.sheetKey)
        Self.markKeys.forEach { markView.layer.removeAnimation(forKey: $0) }
        markView.layer.transform = CATransform3DIdentity
        markView.layer.opacity = 1
    }

    // MARK: - Sheet playback

    private func install(_ sheet: AnimatedIconSheet) {
        sheetView.layer.contents = sheet.sheet.cgImage
        let rotation = ((phase % sheet.frameCount) + sheet.frameCount) % sheet.frameCount

        guard sheet.frameCount > 1, Self.policy != .still else {
            sheetView.layer.contentsRect = sheet.frameRects[rotation]
            return
        }
        let values = Array(sheet.frameRects[rotation...] + sheet.frameRects[..<rotation])
        let animation = CAKeyframeAnimation(keyPath: "contentsRect")
        animation.calculationMode = .discrete
        animation.values = Self.decimated(values)
        animation.duration = sheet.loopDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = Self.epoch
        animation.timeOffset = clockShift
        animation.preferredFrameRateRange = Self.rateRange(step: sheet.frameDuration)
        sheetView.layer.contentsRect = values[0]
        sheetView.layer.add(animation, forKey: Self.sheetKey)
    }

    // MARK: - Decomposed playback

    private func install(_ still: AnimatedIconStill) {
        markView.layer.contents = still.mark.cgImage
        let track = still.track.phased(by: phase)

        // The resting pose, on the MODEL layer — so an icon whose animation is
        // suppressed stays posed rather than snapping to identity.
        markView.layer.transform = CATransform3DConcat(
            CATransform3DMakeScale(track.scales[0], track.scales[0], 1),
            CATransform3DMakeRotation(track.rotations[0], 0, 0, 1)
        )
        markView.layer.opacity = Float(track.alphas[0])
        guard track.frameCount > 1, Self.policy != .still else { return }

        if track.movesScale {
            markView.layer.add(
                Self.animation(track.scales, track: track, keyPath: "transform.scale", shift: clockShift),
                forKey: Self.scaleKey
            )
        }
        if track.movesRotation {
            markView.layer.add(
                Self.animation(track.rotations, track: track, keyPath: "transform.rotation.z", shift: clockShift),
                forKey: Self.rotationKey
            )
        }
        if track.movesAlpha {
            markView.layer.add(
                Self.animation(track.alphas, track: track, keyPath: "opacity", shift: clockShift),
                forKey: Self.alphaKey
            )
        }
    }

    private static func animation(
        _ channel: [Double], track: AnimatedIconMotionTrack, keyPath: String, shift: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.duration = track.loopDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = epoch
        animation.timeOffset = shift
        // Discrete, always.
        //
        // ⚠️ Interpolation is what Low Power has to give up, and it cannot be
        // given up per-state without also being available per-state — so this
        // path is stepped and the rate lives in the ASSET. Measured: halving
        // `preferredFrameRateRange` under interpolation changed nothing (60.0
        // fps presented under a 30 Hz ceiling), because the hint is a ceiling
        // request and not a throttle, and decimating keys changed nothing
        // either while Core Animation interpolated between the survivors.
        animation.calculationMode = .discrete
        animation.values = decimated(Array(channel.dropLast()))
        animation.preferredFrameRateRange = rateRange(step: track.step)
        return animation
    }

    /// Keeps every `stride`-th value. The loop DURATION is unchanged, so the
    /// icon runs at the same speed with half the change instants — not at half
    /// speed, which is the mistake this exists to avoid.
    private static func decimated<T>(_ values: [T]) -> [T] {
        let stride = policy.stride
        guard stride > 1, values.count > stride else { return values }
        return values.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
    }

    /// A RANGE, not a pin: a minimum well below the maximum is what lets the
    /// panel fall toward its floor on a map nobody is touching, which is the
    /// actual battery win. `minimum == maximum` would forbid precisely the idle
    /// state the low rate exists to reach.
    private static func rateRange(step: CFTimeInterval) -> CAFrameRateRange {
        let ceiling = Float(1.0 / (step * Double(policy.stride)))
        return CAFrameRateRange(minimum: min(8, ceiling), maximum: ceiling, preferred: 0)
    }
}
