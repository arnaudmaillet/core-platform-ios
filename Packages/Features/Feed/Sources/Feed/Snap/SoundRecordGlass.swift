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
///        └─ mutedGlyph (🔇, centred on the record, no plate: muted)
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
    /// ⚠️ MUTED IS SAID IN THE MIDDLE (the owner, 2026-10-16): a large
    /// speaker-slash centred on the record, white with a soft shadow and no
    /// plate — no longer a small dark glass badge on the bottom-trailing
    /// diagonal. Its size follows the record's.
    private let mutedGlyph = UIImageView()
    /// The cover darkened behind the muted glyph — the record "off".
    private let coverDim = UIView()
    static let coverDimAlpha: CGFloat = 0.35

    /// The glass's thickness around the record, at least.
    static let rim: CGFloat = 3
    /// The record's side: a bubble's face size (`AvatarImageView
    /// .bubbleDiameter`), centred in the glass, so the cover reads at the
    /// composer avatar's and the author pill's size. nil: the glass less its
    /// rim — the sound sheet's large record.
    var coverSide: CGFloat? = AvatarImageView.bubbleDiameter {
        didSet { setNeedsLayout() }
    }
    /// The muted glyph's point size against the record's side.
    static let mutedGlyphScale: CGFloat = 0.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glass.cornerConfiguration = .capsule()
        glass.clipsToBounds = true
        addSubview(glass)

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        glass.contentView.addSubview(cover)

        coverDim.backgroundColor = .black
        coverDim.alpha = 0
        coverDim.isUserInteractionEnabled = false
        coverDim.clipsToBounds = true
        glass.contentView.addSubview(coverDim)

        mutedGlyph.isHidden = true
        mutedGlyph.tintColor = .white
        mutedGlyph.contentMode = .center
        // Legible over any cover, light or dark, with no plate behind it.
        mutedGlyph.layer.shadowColor = UIColor.black.cgColor
        mutedGlyph.layer.shadowOpacity = 0.45
        mutedGlyph.layer.shadowRadius = 3
        mutedGlyph.layer.shadowOffset = .zero
        glass.contentView.addSubview(mutedGlyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The glyph's point size on a record `side` wide.
    static func mutedGlyphPointSize(forRecordSide side: CGFloat) -> CGFloat {
        (side * mutedGlyphScale).rounded()
    }

    private var mutedGlyphPointSize: CGFloat = 0

    /// Whether the record wears its own glass. Off in the page's action
    /// column (#1872), whose bubble is the column's one glass.
    var drawsGlass = true

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard drawsGlass, window != nil, glass.effect == nil else { return }
        glass.effect = UIGlassEffect(style: .regular)
    }

    /// The muted glyph, and the cover dimmed behind it. On a window it
    /// comes in with a bounce and a fade and leaves with a bounce out and a
    /// fade (the owner, 2026-10-16); off one it just is.
    var showsMutedBadge: Bool {
        get { isShowingMuted }
        set { setMuted(newValue, animated: window != nil) }
    }

    private var isShowingMuted = false

    func setMuted(_ muted: Bool, animated: Bool) {
        guard muted != isShowingMuted else { return }
        isShowingMuted = muted
        setCoverDimmed(muted, animated: animated)
        mutedGlyph.layer.removeAllAnimations()
        guard animated else {
            mutedGlyph.isHidden = !muted
            mutedGlyph.alpha = 1
            mutedGlyph.transform = .identity
            return
        }
        let small = CGAffineTransform(scaleX: Self.mutedOutScale, y: Self.mutedOutScale)
        if muted {
            UIView.performWithoutAnimation {
                mutedGlyph.isHidden = false
                mutedGlyph.alpha = 0
                mutedGlyph.transform = small
            }
            UIView.animate(
                withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0,
                options: [.allowUserInteraction]
            ) {
                self.mutedGlyph.alpha = 1
                self.mutedGlyph.transform = .identity
            }
        } else {
            UIView.animateKeyframes(
                withDuration: 0.26, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) {
                    self.mutedGlyph.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.7) {
                    self.mutedGlyph.transform = small
                    self.mutedGlyph.alpha = 0
                }
            } completion: { _ in
                guard !self.isShowingMuted else { return }
                self.mutedGlyph.isHidden = true
                self.mutedGlyph.alpha = 1
                self.mutedGlyph.transform = .identity
            }
        }
    }

    /// The cover darkened, fading in or out — the muted glyph's ground, and
    /// on the sound sheet the ground of its middle button's 🔇.
    func setCoverDimmed(_ dimmed: Bool, animated: Bool) {
        let alpha: CGFloat = dimmed ? 1 : 0
        guard coverDim.alpha != alpha else { return }
        guard animated else {
            coverDim.alpha = alpha
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.coverDim.alpha = alpha
        }
    }

    /// How small the muted glyph is when it comes and goes.
    static let mutedOutScale: CGFloat = 0.4

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let rimmed = bounds.insetBy(dx: Self.rim, dy: Self.rim)
        let side = min(coverSide ?? rimmed.width, rimmed.width, rimmed.height)
        cover.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        cover.layer.cornerRadius = cover.bounds.width / 2
        // By bounds and centre: the glyph's bounce transforms it.
        mutedGlyph.bounds = CGRect(origin: .zero, size: cover.frame.size)
        mutedGlyph.center = CGPoint(x: cover.frame.midX, y: cover.frame.midY)
        coverDim.frame = cover.frame
        coverDim.layer.cornerRadius = cover.frame.width / 2
        coverDim.backgroundColor = UIColor.black.withAlphaComponent(Self.coverDimAlpha)
        let pointSize = Self.mutedGlyphPointSize(forRecordSide: side)
        if pointSize != mutedGlyphPointSize, pointSize > 0 {
            mutedGlyphPointSize = pointSize
            mutedGlyph.image = UIImage(
                systemName: "speaker.slash.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            )
        }
    }

    #if DEBUG
    /// Where the muted glyph is drawn, and its point size.
    var debugMutedGlyph: (frame: CGRect, pointSize: CGFloat) { (mutedGlyph.frame, mutedGlyphPointSize) }
    /// Whether the cover is dimmed now, and the glyph's running animations.
    var debugCoverDimmed: Bool { coverDim.alpha > 0 }
    var debugMutedGlyphAnimating: Bool { !(mutedGlyph.layer.animationKeys() ?? []).isEmpty }
    #endif

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
