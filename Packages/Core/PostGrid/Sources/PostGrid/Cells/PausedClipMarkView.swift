import DesignSystem
import UIKit

/// The mark a stopped clip wears: a play triangle in the middle of the picture.
///
/// ⚠️ IT BELONGS TO THE PICTURE, NOT TO THE SCREEN — which is why it is a view
/// of its own rather than an image the host centres on itself. A carousel's
/// pages each carry their own clip and their own playhead, so each carries its
/// own mark: the one the viewer stopped slides away under the finger and the
/// page arriving brings its own answer. Centred on the SCREEN it belonged to
/// nothing, and a swipe left it hanging over a picture that was playing.
///
/// Deliberately inert. The mark says a clip is stopped; starting it again is a
/// tap anywhere on the picture, which is a target the size of the media rather
/// than a 56pt glyph.
///
/// It comes and goes with the app's one appear motion (`AppearMotion`,
/// #1151) — a bounce in with a fade on pause, a scale out with a fade on
/// play, a fade under Reduce Motion — the same as `AppButton`'s. The view
/// covers the picture with the glyph centred, so the scale is about the
/// glyph.
public final class PausedClipMarkView: UIImageView {
    /// Reduce Motion, as every animation asks it; swappable for tests.
    public var reducesMotion: @MainActor () -> Bool = { MotionPreference.reducesMotion }
    /// The motions it played, last last — the decision a test reads.
    public private(set) var motions: [AppearMotion.Kind] = []
    /// What was last asked for: true from the start of an appear, false from
    /// the start of a disappear — while it still scales out on screen.
    private var wantsVisible = false

    public init() {
        super.init(frame: .zero)
        image = UIImage(systemName: "play.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold))
        tintColor = UIColor.white.withAlphaComponent(0.85)
        contentMode = .center
        isUserInteractionEnabled = false
        isHidden = true
        // Over a photograph a white glyph can land on white; the shadow is what
        // keeps it readable without a plate behind it.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
        #if DEBUG
        if let variant = GlassPlayMark.variant { installGlass(variant) }
        #endif
    }

    #if DEBUG
    /// The glass triangle prototype (#1369), behind `-glass-play-mark`.
    private var glass: GlassPlayMarkHost?

    /// The triangle in glass, at the glyph's own size and place: the glyph
    /// and its shadow go, the glass draws instead.
    private func installGlass(_ variant: GlassPlayMark.Variant) {
        let size = image?.size ?? CGSize(width: 48, height: 56)
        image = nil
        layer.shadowOpacity = 0
        let host = GlassPlayMarkHost(variant: variant, size: size)
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
        glass = host
    }

    /// The glass's own motion: materialised or not, scaled — never faded by
    /// the view's alpha, which glass does not survive.
    private func setGlassVisible(_ glass: GlassPlayMarkHost, _ visible: Bool, animated: Bool) {
        guard animated, window != nil else {
            isHidden = !visible
            glass.setShown(visible, animated: false, reducesMotion: false) {}
            return
        }
        let reduced = reducesMotion()
        if visible {
            isHidden = false
            record(reduced ? .fadeIn : .bounceIn)
        } else {
            record(reduced ? .fadeOut : .scaleOut)
        }
        glass.setShown(visible, animated: true, reducesMotion: reduced) { [weak self] in
            // An appear that took over keeps the mark.
            guard let self, !visible, !wantsVisible else { return }
            isHidden = true
        }
    }
    #endif

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows or hides the mark. A no-op when it is already in the asked-for
    /// state, so a reconcile that runs on every page change cannot restart
    /// the motion. Asked the other way mid-motion — pause, play, pause inside
    /// it — it reverses from where it is.
    public func setVisible(_ visible: Bool, animated: Bool = true) {
        guard wantsVisible != visible else { return }
        wantsVisible = visible
        #if DEBUG
        if let glass {
            setGlassVisible(glass, visible, animated: animated)
            return
        }
        #endif
        guard animated, window != nil else {
            layer.removeAllAnimations()
            isHidden = !visible
            alpha = 1
            transform = .identity
            return
        }
        if visible {
            isHidden = false
            record(AppearMotion.appear(self, reducesMotion: reducesMotion()))
        } else {
            record(AppearMotion.disappear(self, reducesMotion: reducesMotion(), completion: { [weak self] finished in
                // An appear that took over keeps the mark.
                guard let self, finished, !wantsVisible else { return }
                isHidden = true
                alpha = 1
                transform = .identity
            }))
        }
    }

    /// Whether the mark is asked for — true from the start of its appear,
    /// false from the start of its disappear.
    public var isShowing: Bool { wantsVisible }

    private func record(_ motion: AppearMotion.Kind) {
        if motions.count >= 16 { motions.removeFirst() }
        motions.append(motion)
    }
}
