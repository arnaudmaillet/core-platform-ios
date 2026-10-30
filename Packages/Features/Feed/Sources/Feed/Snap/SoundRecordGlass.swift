import DesignSystem
import UIKit

/// The sound's record IN Liquid Glass (#1150): the cover is the glass's
/// content, not a picture laid on a glass button.
///
/// ```
///   SoundRecordGlass
///   └─ glass (UIVisualEffectView, UIGlassEffect, capsule)
///        contentView
///        └─ cover (the record — turns, `setRecordSpinning`)
/// ```
///
/// Before, the cover was a plain subview of a glass `UIButton`: UIKit drew
/// the glass as the button's background and an opaque picture inside a 5 pt
/// ring over it (the owner, on a device: "laid on top of it rather than
/// inside it"). No muted state since #1931: the sound follows the device.
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
    /// The glass's thickness around the record, at least.
    static let rim: CGFloat = 3
    /// The record's side: a bubble's face size (`AvatarImageView
    /// .bubbleDiameter`), centred in the glass, so the cover reads at the
    /// composer avatar's and the author pill's size. nil: the glass less its
    /// rim — the sound sheet's large record.
    var coverSide: CGFloat? = AvatarImageView.bubbleDiameter {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glass.cornerConfiguration = .capsule()
        glass.clipsToBounds = true
        addSubview(glass)

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        glass.contentView.addSubview(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the record wears its own glass. Off in the page's action
    /// column (#1872), whose bubble is the column's one glass.
    var drawsGlass = true

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard drawsGlass, window != nil, glass.effect == nil else { return }
        glass.effect = UIGlassEffect(style: .regular)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let rimmed = bounds.insetBy(dx: Self.rim, dy: Self.rim)
        let side = min(coverSide ?? rimmed.width, rimmed.width, rimmed.height)
        cover.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        cover.layer.cornerRadius = cover.bounds.width / 2
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
