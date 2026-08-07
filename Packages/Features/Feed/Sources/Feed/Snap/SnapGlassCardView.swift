import UIKit

/// The engaged caption card's surface: a genuine **Liquid Glass** bubble.
///
/// `UIGlassEffect`, not a blur. The difference is not cosmetic — the system
/// material refracts what passes beneath it, draws its own specular edge, and
/// resolves its own luminance against its backdrop, which is exactly what the
/// caption needs while it floats over arbitrary post media. The
/// `systemThinMaterialDark` blur this replaced could only tint; it produced a
/// flat panel with a drawn outline, and over a photo it read as a sticker
/// rather than as glass.
///
/// Three rules come with the material, each learned elsewhere in the app:
///
/// 1. **No border of our own.** The glass already draws its edge and refracts
///    the media under it — that IS the boundary. A `layer.borderWidth`
///    hairline traces the shape correctly but reads as an outline sitting ON
///    the material instead of as the material's own edge (`ToastView`).
/// 2. **Corners via `cornerConfiguration`, never `layer.cornerRadius` +
///    `clipsToBounds`.** A layer radius clips a material that does not know it
///    has been clipped, and the specular edge is drawn on the unclipped shape
///    (`InlineFilterTrayView`).
/// 3. **Materialize only in a window.** Building a real effect off-screen
///    contacts the render server and stalls the main actor for tens of seconds
///    on headless CI simulators — the rule every glass surface here follows.
///
/// It also pins itself to the DARK appearance. `UIGlassEffect` resolves
/// against the *interface style*, not against the media behind it, so on a
/// light-mode device a `.regular` glass renders bright — and the caption's
/// white text would vanish into it over a pale photo. The engaged comments
/// surface is deliberately dark already (the hosted stream sets the same
/// override), so pinning the card matches it and makes the contrast
/// independent of both the device appearance and the post's media.
final class SnapGlassCardView: UIVisualEffectView {
    init() {
        super.init(effect: nil)
        overrideUserInterfaceStyle = .dark
        cornerConfiguration = .corners(
            radius: .fixed(SnapCommentsLayout.stripCardCornerRadius)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Materializes (or dissolves) the glass. Materialization is
    /// window-guarded and idempotent; the dissolve is always safe. Call
    /// inside the engagement's animation block — the `effect` transition
    /// animates.
    func setGlassActive(_ active: Bool) {
        if active {
            guard window != nil, effect == nil else { return }
            let glass = UIGlassEffect(style: .regular)
            // The card is not a touch target in its own right (its taps are
            // the cell's close/page-drive seams), so it must not flex under
            // a finger the way an interactive control does.
            glass.isInteractive = false
            effect = glass
        } else {
            effect = nil
        }
    }
}
