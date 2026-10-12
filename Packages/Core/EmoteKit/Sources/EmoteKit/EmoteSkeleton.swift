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
///   pass, and the skeleton fades out under it.
/// - **A failed load falls back to the system glyph.** No art to be had (a
///   missing file, no icon catalogue, a bake that failed) takes the skeleton
///   away and shows the emote's static glyph for as long as the emote stays
///   on screen: never a skeleton forever. Shown again later (scrolled back,
///   a new screen), the emote asks once more, as it always has — a failure
///   may have been passing, and the icon catalogue arrives after launch.
/// - **The shimmer is decoration.** Reduce Motion (iOS or the app's),
///   Power Saving and idle calm leave a still square (`Conditions`), as on
///   every skeleton. And it lives only as long as the skeleton — while art is
///   pending — so nothing sweeps at rest: an endless animation recomposites
///   the whole frame (#580).
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
        /// Settings → App and Device → Power Saving.
        var powerSaving = false
        /// Nobody has touched the app for a while (`IdleCalm`).
        var idleCalm = false

        static var current: Conditions {
            Conditions(
                reducesMotion: MotionPreference.reducesMotion,
                powerSaving: PowerSavingPreference.isOn,
                idleCalm: IdleCalm.isCalm
            )
        }

        var stillsShimmer: Bool { reducesMotion || powerSaving || idleCalm }
    }

    /// The square's corner, as a share of its side: a soft square, not a
    /// disc — an emote is not an avatar.
    static let cornerFraction: CGFloat = 0.22
    /// How long the skeleton takes to leave from under the art.
    static let fadeDuration: TimeInterval = 0.2

    private var bone: SkeletonBoneView?
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

    /// Whether the skeleton is on show (not counting one fading out).
    var isShowing: Bool { bone != nil }
    /// Whether a show is waiting out its delay.
    private(set) var isScheduled = false
    /// The bone on show. Tests.
    var boneView: SkeletonBoneView? { bone }

    /// Shows the skeleton in `host`, under `sibling` (the art's player, so the
    /// art lands over it), at once or after `delay`.
    func show(in host: UIView, below sibling: UIView, after delay: TimeInterval, engine: EmoteEngine) {
        generation += 1
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

    /// Takes the skeleton away: fading out under the art that replaces it, or
    /// at once (the place was given up, or motion is reduced).
    func hide(fading: Bool = false) {
        generation += 1
        isScheduled = false
        guard let bone else { return }
        self.bone = nil
        guard fading, bone.window != nil, !MotionPreference.reducesMotion else {
            bone.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.allowUserInteraction]) {
            bone.alpha = 0
        } completion: { _ in
            bone.removeFromSuperview()
        }
    }

    private func install(in host: UIView, below sibling: UIView, engine: EmoteEngine) {
        let bone = SkeletonBoneView(rounding: .fixed(0))
        bone.accessibilityElementsHidden = true
        bone.stillsMotion = { [weak engine] in
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
