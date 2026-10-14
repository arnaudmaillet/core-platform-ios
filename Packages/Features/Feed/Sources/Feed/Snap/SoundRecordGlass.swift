import DesignSystem
import UIKit

/// The sound's record IN Liquid Glass (#1150): the cover is the glass's
/// content, not a picture laid on a glass button.
///
/// ```
///   SoundRecordGlass
///   └─ glass (UIVisualEffectView, UIGlassEffect, capsule)
///        contentView
///        ├─ cover (the record — turns, `setRecordSpinning`)
///        └─ badge (a small glass of its own, INSIDE the rim: muted)
/// ```
///
/// Before, the cover and the muted badge were plain subviews of a glass
/// `UIButton`: UIKit drew the glass as the button's background and two
/// opaque views over it, the cover a picture inside a 5 pt ring and the
/// badge a black disc across the rim (the owner, on a device: "laid on top
/// of it rather than inside it").
///
/// Shared by the column's sound bubble and the composer's sound slot, so the
/// two read alike. It takes no touch: its host — a button — keeps the tap,
/// the hold and VoiceOver, and hands its highlight to `setPressed(_:)`, which
/// moves the glass and the record as one.
///
/// ⚠️ The glass materializes on first window attach, like the app's other
/// glass buttons (`SnapRailBoostButton`); and it never gets a
/// `backgroundColor` — glass paints it (`glass-paints-background-color`).
final class SoundRecordGlass: UIView {
    /// The record: the cover's picture.
    let cover = UIImageView()
    private let glass = UIVisualEffectView(effect: nil)
    private let badge = UIVisualEffectView(effect: nil)
    private let badgeGlyph = UIImageView()

    /// The glass's thickness around the record.
    static let rim: CGFloat = 3
    static let badgeSide: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glass.cornerConfiguration = .capsule()
        glass.clipsToBounds = true
        addSubview(glass)

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        glass.contentView.addSubview(cover)

        badge.cornerConfiguration = .capsule()
        badge.isHidden = true
        badgeGlyph.image = UIImage(
            systemName: "speaker.slash.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        )
        badgeGlyph.tintColor = .white
        badgeGlyph.contentMode = .center
        badge.contentView.addSubview(badgeGlyph)
        glass.contentView.addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, glass.effect == nil else { return }
        glass.effect = UIGlassEffect(style: .regular)
        let tinted = UIGlassEffect(style: .regular)
        // Dark glass, so the white glyph reads over any cover, light or dark.
        tinted.tintColor = UIColor.black.withAlphaComponent(0.55)
        badge.effect = tinted
    }

    /// The muted badge.
    var showsMutedBadge: Bool {
        get { !badge.isHidden }
        set { badge.isHidden = !newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        cover.frame = bounds.insetBy(dx: Self.rim, dy: Self.rim)
        cover.layer.cornerRadius = cover.bounds.width / 2
        badge.frame = Self.badgeFrame(in: bounds)
        badgeGlyph.frame = badge.bounds
    }

    /// The badge's frame: on the circle's bottom-trailing diagonal, its edge
    /// one rim inside the glass's — inside the bubble, never across it.
    static func badgeFrame(in bounds: CGRect) -> CGRect {
        let radius = min(bounds.width, bounds.height) / 2
        let reach = max(0, radius - rim - badgeSide / 2) / 2.squareRoot()
        let center = CGPoint(x: bounds.midX + reach, y: bounds.midY + reach)
        return CGRect(
            x: center.x - badgeSide / 2, y: center.y - badgeSide / 2, width: badgeSide, height: badgeSide
        )
    }

    /// The press: the glass and the record grow together, and settle back.
    func setPressed(_ pressed: Bool) {
        UIView.animate(
            withDuration: pressed ? 0.18 : 0.35, delay: 0,
            usingSpringWithDamping: pressed ? 1 : 0.6, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.transform = pressed ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
        }
    }

    /// Turns the record while the post plays audibly; Reduce Motion stills it.
    func setSpinning(_ spinning: Bool) {
        cover.layer.setRecordSpinning(spinning, reducesMotion: MotionPreference.reducesMotion)
    }

    var isSpinning: Bool {
        cover.layer.animation(forKey: CALayer.recordSpinKey) != nil && cover.layer.speed != 0
    }
}
