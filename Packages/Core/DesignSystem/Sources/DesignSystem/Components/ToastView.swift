import UIKit

/// A transient confirmation banner — the answer to actions whose only evidence
/// is off-screen ("Copied", "Report sent"). A floating Liquid Glass capsule
/// that rises from the bottom safe area, holds briefly, and leaves.
///
/// Deliberately not a `UIAlertController`: those demand a dismissal tap for
/// something the user has already finished doing. Deliberately not a nav-bar
/// prompt either — the profile's bar is transparent over media and owns no
/// spare row.
///
/// Presentation is view-controller-agnostic (`present(_:in:)` takes any view),
/// and toasts are self-owning: the caller fires and forgets. Only one shows at
/// a time per host view — a second replaces the first rather than stacking, so
/// a fast double-tap can't build a tower.
///
/// **Why the animation looks the way it does.** Two house rules about glass
/// constrain it, and both were learned the expensive way elsewhere in this
/// app:
/// - **Never move a glass lens with `CGAffineTransform`** (the Messages
///   header's finding): a transform moves the *rendered* material, so the
///   capsule carries a stale backdrop as it travels and its edge softens. The
///   slide animates a layout constraint instead, which re-renders the glass at
///   its true position every frame — the refraction stays live over whatever
///   it passes.
/// - **Never animate a `UIVisualEffectView`'s alpha** (the chat input bar's
///   rule), which includes fading an ancestor — group opacity reaches the
///   effect view just the same. The capsule arrives and leaves by swapping
///   `effect` inside the animation block, which is how UIKit interpolates
///   glass; only the label row, which is ordinary content, uses alpha.
@MainActor
public final class ToastView: UIView {
    private enum Metrics {
        /// Gap between the capsule and the bottom safe area.
        static let bottomGap: CGFloat = Spacing.lg
        /// How far the capsule travels on entrance/exit.
        static let travel: CGFloat = 24
        static let visibleDuration: TimeInterval = 1.8
        static let transitionDuration: TimeInterval = 0.32
        /// Resting shadow strength. Soft and low-contrast: the glass already
        /// separates itself: the shadow only grounds it.
        static let shadowOpacity: Float = 0.22
    }

    /// Marks the currently-visible toast in a host view, so the next one can
    /// retire it instead of overlapping.
    private static let hostTag = 0x70A570

    private var dismissWorkItem: DispatchWorkItem?
    private let backdrop = UIVisualEffectView(effect: nil)
    /// The capsule's distance below its resting place. Driven instead of a
    /// transform (see the type doc); `travel` while off, zero at rest.
    private var slide: NSLayoutConstraint?
    private let row = UIStackView()

    /// Shows `message` over `host`, replacing any toast already up there.
    ///
    /// - Parameters:
    ///   - message: the confirmation text — short, past-tense, no punctuation.
    ///   - symbol: an optional SF Symbol leading the text.
    ///   - host: the view to present in. Pass the view controller's `view`;
    ///     the capsule pins to its safe area, so it clears tab and tool bars.
    public static func present(
        _ message: String,
        symbol: String? = "checkmark.circle.fill",
        in host: UIView
    ) {
        host.viewWithTag(hostTag).flatMap { $0 as? ToastView }?.dismiss(animated: false)

        let toast = ToastView(message: message, symbol: symbol)
        toast.tag = hostTag
        let slide = toast.bottomAnchor.constraint(
            equalTo: host.safeAreaLayoutGuide.bottomAnchor,
            constant: -Metrics.bottomGap + Metrics.travel
        )
        toast.slide = slide
        toast.constrain(in: host) { parent in
            toast.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            slide
            // Never wider than the host, however long the message.
            toast.leadingAnchor.constraint(
                greaterThanOrEqualTo: parent.layoutMarginsGuide.leadingAnchor
            )
            toast.trailingAnchor.constraint(
                lessThanOrEqualTo: parent.layoutMarginsGuide.trailingAnchor
            )
        }
        toast.animateIn()
    }

    private init(message: String, symbol: String?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // Announced rather than read on focus: the user's attention is on what
        // they just did, and the capsule is gone before VoiceOver could reach it.
        UIAccessibility.post(notification: .announcement, argument: message)

        // The capsule's shape is driven by the corner CONFIGURATION, not a
        // layer radius: the glass renders its own boundary refraction against
        // that shape, and a layer radius would clip a material that doesn't
        // know it has been clipped. `.capsule()` keeps the ends circular at
        // any height Dynamic Type resolves to.
        // No border of our own: the glass draws its own specular edge and
        // refracts what passes under it, which is what defines the boundary.
        // A `layer.borderWidth` hairline on top traces the capsule correctly
        // (the corner configuration drives the layer radius — verified), but
        // it reads as a drawn outline sitting ON the material rather than as
        // the material's own edge. Same family of mistake as stacking a
        // second material inside a system-supplied capsule.
        backdrop.isUserInteractionEnabled = false
        backdrop.clipsToBounds = true
        backdrop.cornerConfiguration = .capsule()
        backdrop.pin(to: self)

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        // Adaptive colors over an adaptive material: `UIGlassEffect` resolves
        // its own luminance against whatever it sits over, so the label tracks
        // it in both appearances without a hand-picked color.
        label.textColor = .label
        label.numberOfLines = 2

        var arranged: [UIView] = []
        if let symbol, let image = UIImage(systemName: symbol) {
            let glyph = UIImageView(image: image)
            glyph.tintColor = .label
            glyph.contentMode = .scaleAspectFit
            glyph.setContentHuggingPriority(.required, for: .horizontal)
            arranged.append(glyph)
        }
        arranged.append(label)

        row.addArrangedSubviews(arranged)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        row.isUserInteractionEnabled = false
        // Ordinary content, so alpha is the right lever here — the rule the
        // type doc cites is about the effect view, not what rides inside it.
        row.alpha = 0
        row.constrain(in: backdrop.contentView) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.md)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.md)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.lg)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.lg)
        }

        // The shadow lives on self, never on the backdrop: that view clips to
        // its capsule, and a clipping view cannot cast a shadow.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // Materialized on window attach, never in init: building a real effect
        // off-screen contacts the render server and stalls the main actor for
        // tens of seconds on headless CI simulators (the rule `ChatInputBar`
        // and `InboxCategoryBar` both follow).
        //
        // Only the FIRST attach seeds it; from then on `animateIn`/`dismiss`
        // own the effect, and re-seeding here would refill a capsule that is
        // deliberately mid-dissolve.
        guard window != nil, !hasMaterialized else { return }
        hasMaterialized = true
        backdrop.effect = Self.makeGlass()
    }

    private var hasMaterialized = false

    /// Regular glass — the system's floating-chrome material. Not `.clear`,
    /// which is for glass over deliberately busy media and would drop the
    /// contrast this has to keep over an arbitrary profile banner.
    private static func makeGlass() -> UIGlassEffect {
        let glass = UIGlassEffect(style: .regular)
        // The toast is not a touch target (`isUserInteractionEnabled = false`),
        // so it must not flex under a finger the way the search field does.
        glass.isInteractive = false
        return glass
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Trace the shadow onto the capsule the corner configuration actually
        // resolved, rather than assuming height/2 — `.capsule()` clamps itself
        // on very short or very wide bounds.
        let radius = backdrop.effectiveRadius(corner: .allCorners)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }

    private func animateIn() {
        // Land the pre-entrance state before animating: the capsule sits one
        // `travel` low, with no glass and no shadow to inherit.
        superview?.layoutIfNeeded()
        slide?.constant = -Metrics.bottomGap
        UIView.animate(withDuration: Metrics.transitionDuration, delay: 0, options: .curveEaseOut) {
            // Layout drives the slide, so the material re-renders in place
            // each frame instead of being carried as a stale image.
            self.superview?.layoutIfNeeded()
            self.backdrop.effect = Self.makeGlass()
            self.row.alpha = 1
            // A CALayer property set inside a UIView animation block adopts
            // that block's timing, so the shadow arrives with the capsule
            // instead of snapping on at frame 0.
            self.layer.shadowOpacity = Metrics.shadowOpacity
        }

        let dismissal = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissWorkItem = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.visibleDuration, execute: dismissal)
    }

    private func dismiss(animated: Bool) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        // The outgoing toast must stop answering `viewWithTag` immediately, or
        // a replacement arriving mid-fade would find and re-dismiss it.
        tag = 0
        guard animated else {
            removeFromSuperview()
            return
        }
        slide?.constant = -Metrics.bottomGap + Metrics.travel
        UIView.animate(withDuration: Metrics.transitionDuration, delay: 0, options: .curveEaseIn) {
            self.superview?.layoutIfNeeded()
            // Dissolving the effect is how glass leaves; fading the view would
            // put group opacity on the effect view (see the type doc).
            self.backdrop.effect = nil
            self.row.alpha = 0
            // Without this the capsule dissolves and leaves its shadow behind
            // as a grey smear for the length of the exit.
            self.layer.shadowOpacity = 0
        } completion: { _ in
            self.removeFromSuperview()
        }
    }
}

private extension UIStackView {
    func addArrangedSubviews(_ views: [UIView]) {
        views.forEach(addArrangedSubview)
    }
}
