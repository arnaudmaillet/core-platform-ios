import DesignSystem
import UIKit

/// The square that holds an animated emote's place while its art is on its
/// way (#987): the app's own skeleton bone (`SkeletonBoneView`), so it
/// shimmers in step with every other skeleton on screen and rests when they
/// do. One per emote place: a label's emote (`EmoteLabel`), the composer's
/// (`EmoteAttachmentView`), a panel or strip tile (`EmoteTileView`).
///
/// ## The rules, on every surface
///
/// - **Only while art is PENDING.** Art in memory installs in the same pass
///   and never shows one. Art that is only READ — a bundled seed
///   (`EmoteSeeds`), a sheet on disk, a map icon — leaves the place empty
///   for the few frames the read takes, and shows the skeleton only if the
///   read is late (`EmoteEngine.skeletonDelay`). Art that must be BAKED
///   shows it at once.
/// - **The emote's own square.** Exactly where the art goes — the em box
///   inline, the tile's square — so the swap moves nothing.
/// - **No glyph in between.** The art goes in over the skeleton in the same
///   pass, and the two trade places in one arrival (`reveal`, #1071).
/// - **A failed load keeps a STILL skeleton, never the glyph (#1504, the
///   owner 2026-10-21: an animated emote has no static equivalent).** No art
///   to be had (a missing file, no icon catalogue, a bake that failed) leaves
///   the square to a bone with no shimmer (`showFailed`) for as long as the
///   emote stays on screen — nothing sweeps at rest (#580). Shown again later
///   (scrolled back, a new screen), the emote asks once more, as it always
///   has — a failure may have been passing, and the icon catalogue arrives
///   after launch.
/// - **The shimmer is decoration.** Reduce Motion (iOS or the app's),
///   Low Power Mode and idle calm leave a still square (`Conditions`), as on
///   every skeleton. And it lives only as long as the skeleton — while art is
///   pending — so nothing sweeps at rest: an endless animation recomposites
///   the whole frame (#580).
///
/// ## The arrival (#1071)
///
/// Art that lands over a skeleton plays ONE hand-off, the same on every
/// surface (`reveal`): the art bounces in — the keyboard's own arrival
/// (#731), from nothing and a third of its size, past it and back, on a
/// spring — while the skeleton fades and shrinks a little from under it. Both
/// carry one begin time, so they start in the same frame, on the same square.
///
/// - **Only over a skeleton.** Art in memory and art read before the
///   skeleton's grace was up never bounce.
/// - **The shimmer's gates.** Under any of them (`Conditions.stillsShimmer`:
///   Reduce Motion, Low Power Mode, idle calm) the art takes the square at once
///   and the skeleton goes with no fade: a straight swap.
/// - **It ends.** A spring and a fade, both one-shot; the skeleton leaves the
///   hierarchy when its fade ends. Anything that gives the place up mid-way
///   (`hide()`: reuse, an edit, leaving the window) ends both at once, at
///   rest: the art at full alpha and its own size, no skeleton.
///
/// EmoteKit already depends on DesignSystem (the picker's click, the motion
/// preferences), so the bone is DesignSystem's own rather than a copy.
@MainActor
final class EmoteSkeleton {
    /// What stills the shimmer: decoration's gates
    /// (`MotionPreference.stillsDecoration`), spelled out so a test can set
    /// each one without touching process-wide settings.
    struct Conditions: Equatable {
        /// iOS Reduce Motion or the app's own switch.
        var reducesMotion = false
        /// Low Power Mode, followed (Settings → App and Device, #1808).
        var lowPowerMode = false
        /// Nobody has touched the app for a while (`IdleCalm`).
        var idleCalm = false

        static var current: Conditions {
            Conditions(
                reducesMotion: MotionPreference.reducesMotion,
                lowPowerMode: LowPowerMode.savesBattery,
                idleCalm: IdleCalm.isCalm
            )
        }

        var stillsShimmer: Bool { reducesMotion || lowPowerMode || idleCalm }
    }

    /// The square's corner, as a share of its side: a soft square, not a
    /// disc — an emote is not an avatar.
    static let cornerFraction: CGFloat = 0.22
    /// How long the skeleton takes to leave from under the art.
    static let fadeDuration: TimeInterval = 0.2
    /// What the skeleton shrinks to, around its centre, as it leaves from
    /// under arriving art.
    static let leavingScale: CGFloat = 0.85

    /// The art's arrival over the skeleton: the emote keyboard's bounce
    /// (#731), kept exactly as the owner approved it there.
    ///
    /// It is what `UIView.animate(withDuration: 0.5, delay: 0,
    /// usingSpringWithDamping: 0.55, initialSpringVelocity: 0.6)` from alpha 0
    /// and a third of the size put on the layer, rebuilt as Core Animation
    /// springs so it can share an explicit begin time with the skeleton's exit
    /// (`reveal`) — UIKit gives its animations none until the commit.
    enum Arrival {
        /// The art starts invisible, at this share of its size.
        static let fromScale: CGFloat = 0.3
        /// UIKit's spring for that call, read off the layer it animated:
        /// mass 1, a damping ratio of 0.55, cut at the call's 0.5 s.
        /// `theArrivalIsTheKeyboardsBounce` holds them to UIKit's own.
        static let duration: CFTimeInterval = 0.5
        static let mass: CGFloat = 1
        static let stiffness: CGFloat = 548.81303941581
        static let damping: CGFloat = 25.769434950986607
        static let initialVelocity: CGFloat = 0.6
        /// The keys the arrival's animations go under.
        static let fadeKey = "emote.arrival.opacity"
        static let bounceKey = "emote.arrival.transform"
        static let skeletonFadeKey = "emote.leaving.opacity"
        static let skeletonShrinkKey = "emote.leaving.transform"

        /// One half of the art's arrival on `keyPath`.
        static func spring(_ keyPath: String, from: Any, to: Any, begin: CFTimeInterval) -> CASpringAnimation {
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = mass
            spring.stiffness = stiffness
            spring.damping = damping
            spring.initialVelocity = initialVelocity
            spring.duration = duration
            spring.fromValue = from
            spring.toValue = to
            spring.beginTime = begin
            spring.fillMode = .both
            return spring
        }
    }

    private var bone: SkeletonBoneView?
    /// What says which gates hold, when the art lands.
    private weak var engine: EmoteEngine?
    /// The skeleton fading out from under arriving art, until its fade ends.
    private(set) var leavingBone: SkeletonBoneView?
    /// The art bouncing in, until its spring ends.
    private(set) weak var arrivingArt: UIView?
    /// How many arrivals this place has played. Tests.
    private(set) var revealCount = 0
    /// Whether an arrival is in flight.
    var isRevealing: Bool { leavingBone != nil || arrivingArt != nil }
    /// Bumped by every show and hide, so a delayed show that was overtaken
    /// does nothing.
    private var generation = 0
    /// Where the square goes, in the host's coordinates.
    var frame: CGRect = .zero {
        didSet {
            guard frame != oldValue, let bone else { return }
            Self.place(bone, in: frame)
        }
    }

    /// Whether the skeleton is on show (not counting one fading out:
    /// `leavingBone`).
    var isShowing: Bool { bone != nil }
    /// Whether the bone on show is a failed load's still one (`showFailed`).
    private(set) var isFailed = false
    /// Whether a show is waiting out its delay.
    private(set) var isScheduled = false
    /// The bone on show. Tests.
    var boneView: SkeletonBoneView? { bone }

    /// Shows the skeleton in `host`, under `sibling` (the art's player, so the
    /// art lands over it), at once or after `delay`.
    func show(in host: UIView, below sibling: UIView, after delay: TimeInterval, engine: EmoteEngine) {
        endReveal()
        generation += 1
        self.engine = engine
        guard bone == nil else { return }
        guard delay > 0 else {
            install(in: host, below: sibling, engine: engine)
            return
        }
        let expected = generation
        isScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak host, weak sibling, weak engine] in
            guard let self, self.generation == expected else { return }
            self.isScheduled = false
            guard let host, let sibling, let engine, sibling.superview === host else { return }
            self.install(in: host, below: sibling, engine: engine)
        }
    }

    /// Takes the skeleton away: fading out (a failed load: the glyph takes the
    /// square), or at once (the place was given up, or motion is reduced).
    /// An arrival in flight ends at rest either way.
    func hide(fading: Bool = false) {
        endReveal()
        generation += 1
        isScheduled = false
        isFailed = false
        guard let bone else { return }
        self.bone = nil
        guard fading, bone.window != nil, !MotionPreference.reducesMotion else {
            bone.removeFromSuperview()
            return
        }
        leavingBone = bone
        UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.allowUserInteraction]) {
            bone.alpha = 0
        } completion: { [weak self] _ in
            bone.removeFromSuperview()
            if self?.leavingBone === bone { self?.leavingBone = nil }
        }
    }

    /// No art to be had (#1504): a STILL bone holds the square, at once, for
    /// as long as the place does — never the glyph, and nothing sweeping at
    /// rest (#580). A shimmering bone on show is swapped for a still one.
    func showFailed(in host: UIView, below sibling: UIView, engine: EmoteEngine) {
        endReveal()
        generation += 1
        isScheduled = false
        self.engine = engine
        guard !isFailed || bone == nil else { return }
        bone?.removeFromSuperview()
        bone = nil
        isFailed = true
        install(in: host, below: sibling, engine: engine, still: true)
    }

    /// Hands the square over to `art` — the art's view, dressed and shown, a
    /// sibling over the skeleton in the same square — with the arrival above
    /// if a skeleton is on show; otherwise there is nothing to hand over and
    /// the art simply stays (a pending show is called off).
    ///
    /// Every animation carries the same explicit begin time and explicit
    /// from-values: nothing is read from a presentation layer (a staged start
    /// that never rendered would hand a spring its end value as its start),
    /// and nothing goes through a UIKit animation block (a no-animation scope
    /// — a diffable apply, `performWithoutAnimation` — would swallow it).
    ///
    /// - Returns: whether the arrival plays.
    @discardableResult
    func reveal(_ art: UIView) -> Bool {
        generation += 1
        isScheduled = false
        // No skeleton: nothing to hand over, and an arrival still in flight
        // (the art dressed again, a playback slot freed) plays on.
        guard let bone else { return false }
        endReveal()
        self.bone = nil
        isFailed = false
        let conditions = engine?.skeletonConditions() ?? .current
        guard bone.window != nil, art.window != nil, art.superview === bone.superview,
              !conditions.stillsShimmer else {
            bone.removeFromSuperview()
            return false
        }
        revealCount += 1
        leavingBone = bone
        arrivingArt = art
        let expected = revealCount
        // ONE begin time for both halves, in the host's time (the two are
        // siblings in it): the same frame, whenever the commit lands.
        let begin = art.layer.convertTime(CACurrentMediaTime(), from: nil)
        let shrunk = CATransform3DMakeScale(Self.leavingScale, Self.leavingScale, 1)
        let staged = CATransform3DMakeScale(Arrival.fromScale, Arrival.fromScale, 1)
        // The models are where each half ends — the skeleton gone, the art at
        // rest — outside any animation block, so nothing implicit joins in.
        UIView.performWithoutAnimation {
            bone.alpha = 0
            bone.layer.transform = shrunk
            art.alpha = 1
            art.transform = .identity
        }
        removeArrivalAnimations(from: art)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = CATransform3DIdentity
        shrink.toValue = shrunk
        for leaving in [fade, shrink] {
            leaving.duration = Self.fadeDuration
            leaving.timingFunction = CAMediaTimingFunction(name: .easeOut)
            leaving.beginTime = begin
            leaving.fillMode = .both
        }
        // Weakly: the bone's layer holds the animation, which holds this.
        fade.delegate = AnimationEnd { [weak self, weak bone] in
            guard let bone else { return }
            bone.removeFromSuperview()
            if self?.leavingBone === bone { self?.leavingBone = nil }
        }
        bone.layer.add(fade, forKey: Arrival.skeletonFadeKey)
        bone.layer.add(shrink, forKey: Arrival.skeletonShrinkKey)

        let bounce = Arrival.spring("transform", from: staged, to: CATransform3DIdentity, begin: begin)
        bounce.delegate = AnimationEnd { [weak self, weak art] in
            guard let self, let art, self.arrivingArt === art, self.revealCount == expected else { return }
            self.arrivingArt = nil
        }
        art.layer.add(Arrival.spring("opacity", from: 0, to: 1, begin: begin), forKey: Arrival.fadeKey)
        art.layer.add(bounce, forKey: Arrival.bounceKey)
        return true
    }

    private func removeArrivalAnimations(from art: UIView) {
        art.layer.removeAnimation(forKey: Arrival.fadeKey)
        art.layer.removeAnimation(forKey: Arrival.bounceKey)
    }

    /// Ends an arrival in flight at once, at rest: the art at full alpha and
    /// its own size, the leaving skeleton gone.
    private func endReveal() {
        if let art = arrivingArt {
            arrivingArt = nil
            removeArrivalAnimations(from: art)
            art.alpha = 1
            art.transform = .identity
        }
        if let leaving = leavingBone {
            leavingBone = nil
            leaving.layer.removeAllAnimations()
            leaving.removeFromSuperview()
        }
    }

    private func install(in host: UIView, below sibling: UIView, engine: EmoteEngine, still: Bool = false) {
        let bone = SkeletonBoneView(rounding: .fixed(0))
        bone.accessibilityElementsHidden = true
        // Set before the bone joins the window, which is when it reads it.
        bone.stillsMotion = still ? { true } : { [weak engine] in
            engine?.skeletonConditions().stillsShimmer ?? MotionPreference.stillsDecoration
        }
        Self.place(bone, in: frame)
        host.insertSubview(bone, belowSubview: sibling)
        self.bone = bone
    }

    private static func place(_ bone: SkeletonBoneView, in frame: CGRect) {
        bone.frame = frame
        // `.fixed(0)` leaves the corner to the host: it follows the side.
        bone.layer.cornerRadius = min(frame.width, frame.height) * cornerFraction
    }
}

/// Runs a closure when a `CAAnimation` stops — run to its end OR removed (a
/// place given up mid-arrival): either way the teardown is due. Core
/// Animation retains its delegate for the animation's life, so this needs no
/// owner.
private final class AnimationEnd: NSObject, CAAnimationDelegate {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        // Core Animation calls its delegates on the main thread.
        let run = body
        MainActor.assumeIsolated { run() }
    }
}
