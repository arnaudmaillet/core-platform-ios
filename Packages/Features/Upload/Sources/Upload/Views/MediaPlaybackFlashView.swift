import DesignSystem
import UIKit

/// The glyph that flashes in the middle of a clip when a tap on the picture
/// plays or pauses it.
///
/// ⚠️ **IT SHOWS WHAT JUST HAPPENED, NOT WHAT A NEXT TAP WOULD DO.** Asked for
/// as "a play icon and a pause icon, according to the state, appearing briefly
/// in the middle of the video each time it is tapped". A tap on the picture
/// is a control nobody can see; the flash is its answer — so a clip that has
/// just stopped shows a pause, and one that has just started shows a play. The
/// other convention (drawing the ACTION a next tap would take) is right for a
/// button that stays on screen; a glyph that is gone in half a second has to
/// name the state it leaves behind.
///
/// ⚠️ **A SUBVIEW OF THE SCREEN, LAID OVER WHICHEVER SURFACE IS PLAYING.** The
/// clip plays on a page of the canvas or inside the crop box, and those are two
/// different views in two different trees; one flash owned by the screen and
/// centred on `playingSurface` serves both, where one per surface would be two
/// copies of the same curve.
@MainActor
final class MediaPlaybackFlashView: UIView {
    private enum Metrics {
        static let side: CGFloat = 76
        static let glyph: CGFloat = 30
        /// ⚠️ **IN, HOLD, OUT — AND THE HOLD IS SHORT.** Long enough to be read
        /// with a glance at the picture, short enough that a second tap a
        /// moment later is not answered over the top of the first.
        static let arrival: TimeInterval = 0.2
        static let hold: TimeInterval = 0.28
        static let departure: TimeInterval = 0.24
        static let arrivingScale: CGFloat = 0.72
        static let leavingScale: CGFloat = 1.12
    }

    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let glyph = UIImageView()
    /// Bumped by every flash, so a flash overtaken by a newer one does not
    /// fade the newer one out when its own hold ends.
    private var generation = 0

    /// Whether the device asks for less motion — a seam, so a test can state it
    /// rather than inherit the setting of the machine that runs it.
    var reducesMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Metrics.side, height: Metrics.side))
        isUserInteractionEnabled = false
        alpha = 0
        glass.cornerConfiguration = .capsule()
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: Metrics.glyph, weight: .semibold
        )
        glyph.frame = bounds
        glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(glyph)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Flashes the glyph for `paused`, centred at `point` in the superview.
    func flash(paused: Bool, at point: CGPoint) {
        generation += 1
        let mine = generation
        glyph.image = UIImage(systemName: paused ? "pause.fill" : "play.fill")
        center = point
        superview?.bringSubviewToFront(self)
        layer.removeAllAnimations()
        #if DEBUG
        debugFlashes.append(paused)
        #endif
        // ⚠️ **SAID TO VOICEOVER TOO.** The glyph is decoration for the eye; a
        // listener gets the same news as an announcement, since the tap that
        // caused it landed on a picture with nothing to focus.
        UIAccessibility.post(notification: .announcement, argument: paused ? "Paused" : "Playing")
        guard !reducesMotion() else {
            alpha = 1
            transform = .identity
            // ⚠️ **NO `.beginFromCurrentState`.** It takes the from-value from the
            // PRESENTATION layer, which still holds the last flash's committed
            // 0 — the 1 staged just above is not committed yet — so every flash
            // after the first faded from 0 to 0 and was never seen
            // (`uiview-animate-from-value-trap`). The flash in flight is
            // already cancelled by `removeAllAnimations` above.
            UIView.animate(withDuration: Metrics.departure, delay: Metrics.hold, options: []) {
                self.alpha = 0
            }
            return
        }
        alpha = 0
        transform = CGAffineTransform(scaleX: Metrics.arrivingScale, y: Metrics.arrivingScale)
        UIView.animate(
            withDuration: Metrics.arrival, delay: 0, usingSpringWithDamping: 0.7,
            initialSpringVelocity: 0, options: []
        ) {
            self.alpha = 1
            self.transform = .identity
        } completion: { _ in
            guard self.generation == mine else { return }
            UIView.animate(
                withDuration: Metrics.departure, delay: Metrics.hold, options: [.curveEaseIn]
            ) {
                self.alpha = 0
                self.transform = CGAffineTransform(scaleX: Metrics.leavingScale, y: Metrics.leavingScale)
            }
        }
    }

    #if DEBUG
    /// Internal for tests: every flash asked for, as the state it named.
    private(set) var debugFlashes: [Bool] = []
    var debugGlyphName: String? { glyph.image.flatMap { $0.isSymbolImage ? $0.description : nil } }
    #endif
}
