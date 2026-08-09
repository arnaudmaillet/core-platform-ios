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
/// It INHERITS its appearance rather than pinning one, which is what lets a
/// standard dynamic `.regular` glass resolve its own translucency, specular
/// highlights, and text contrast for the ambient theme.
///
/// It used to pin itself to dark, and the reason it could stop is that the
/// host now answers the question properly. `UIGlassEffect` resolves against
/// the *interface style*, not against what is behind it, so a bubble over a
/// pale photo in light mode would render bright and swallow its own text —
/// which is why the override existed. But the two grounds this bubble can
/// sit on now say different things: a MEDIA panel is pinned dark by its host
/// (the material is the only contrast over an arbitrary photo), while a TEXT
/// panel follows the device and sits on a ground that does the same. Pinning
/// the card was correct only while both were dark; inheriting is correct in
/// both cases, because the inherited answer is already the right one.
final class SnapGlassCardView: UIVisualEffectView {
    init() {
        super.init(effect: nil)
        cornerConfiguration = .corners(
            radius: .fixed(SnapCommentsLayout.stripCardCornerRadius)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }


    /// Materializes (or dissolves) the glass. Materialization is
    /// window-guarded and idempotent; the dissolve is always safe.
    ///
    /// MATERIALIZATION IS NEVER ANIMATED. Setting `effect` inside an ambient
    /// animation — and this one runs during a navigation push, whose
    /// transition is exactly that — makes UIKit cross-fade from "no effect"
    /// to the built material. The intermediate frames of that cross-fade are
    /// a flat opaque grey, which reads as the bubble rendering DARK and then
    /// snapping to light. (Measured: #8E8E8E → #AAAAAA → #AEAEAE → #FCFCFC
    /// over ~3 frames, while the glass itself logged `.light` at every
    /// step — the appearance was never wrong, only unsettled.)
    ///
    /// The DISSOLVE keeps whatever animation context it is called in: it
    /// rides the disengagement's spring on purpose.
    func setGlassActive(_ active: Bool) {
        if active {
            guard window != nil, effect == nil else { return }
            let glass = UIGlassEffect(style: .regular)
            // The card is not a touch target in its own right (its taps are
            // the cell's close/page-drive seams), so it must not flex under
            // a finger the way an interactive control does.
            glass.isInteractive = false
            UIView.performWithoutAnimation { effect = glass }
            // `-glass-log` prints the style this glass RESOLVED against, and
            // whether an animation was in flight when it did. Worth keeping:
            // a bubble that renders wrong is almost never a wrong appearance
            // — it is an unsettled material or an alpha-faded effect view,
            // and those look identical to the eye. This log is what told
            // those apart once (style was `.light` at every step while the
            // bubble looked dark).
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-glass-log") {
                print("GLASSLOG: materialize style=\(traitCollection.userInterfaceStyle.rawValue) "
                      + "inAnimation=\(UIView.inheritedAnimationDuration > 0) "
                      + "window=\(window != nil)")
            }
            #endif
        } else {
            effect = nil
        }
    }
}
