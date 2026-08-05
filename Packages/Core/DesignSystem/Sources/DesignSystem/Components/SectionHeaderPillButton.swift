import UIKit

/// Every sectioned list's header, in the two shapes a section header has:
/// a large bold title while it sits in the flow, and a floating glass capsule
/// once it pins to the top.
///
/// **Why two shapes.** In the flow a header is *typography* — it introduces the
/// rows under it and wants the weight and size that says so. Pinned, it is
/// *chrome* — it is floating over content it no longer introduces, and a large
/// title parked over scrolling rows reads as a title that failed to scroll
/// away. The system's own large-title navigation bars make exactly this move,
/// and a list whose headers stayed one size looked, next to them, like a screen
/// that had forgotten to.
///
/// **A real `UIButton` on `UIButton.Configuration.glass()`** in the pinned
/// state, not a `UIVisualEffectView` with a tap recognizer bolted on. That is
/// what buys the native Liquid Glass press behaviour — the deform-and-settle
/// spring, the highlight, the accessibility treatment of a control — none of
/// which a recognizer over an effect view would produce.
///
/// It lives here rather than in any one feature because five lists across two
/// features need the same header: the inbox's two tables, the compose picker's
/// and the search screen's collection views, and For You's Following list. All
/// of them host it; none of them owns how it looks.
public final class SectionHeaderPillButton: UIButton {
    /// Which shape the header is currently wearing.
    public enum Presentation: Equatable, Sendable {
        /// In the flow: a large bold title, no background.
        case inline
        /// Pinned to the top: the compact glass capsule.
        case pinned
    }

    public enum Metrics {
        /// Inside the pill. Horizontal is twice the vertical so the text clears
        /// the corner curve instead of crowding into it.
        public static let textInsets = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        )
        /// Around the pill, symmetric: it floats in the band rather than
        /// hanging from either edge of it.
        public static let float = Spacing.sm
        /// Extra space above a header that FOLLOWS another section.
        ///
        /// ⚠️ The first header never gets it, and the asymmetry is the point.
        /// It sits directly under the navigation bar's tab capsule, where a gap
        /// reads as the screen failing to fill — there is nothing above it to be
        /// separated from. Every later header IS separating two runs of content,
        /// and without this its pill crowds the last row of the section before
        /// it, reading as part of that section rather than the start of the next.
        public static let sectionGap = Spacing.lg
        /// How close to the pin line the header forms its capsule.
        ///
        /// Slightly BEFORE it locks, not at the instant it does: a morph that
        /// begins on contact reads as a reaction to the collision, where one
        /// that begins just short of it reads as the header preparing to land.
        public static let morphDistance: CGFloat = 12
        /// The crossfade. Short enough to feel like a consequence of the scroll
        /// rather than an animation playing over it.
        public static let morphDuration: TimeInterval = 0.22
    }

    /// Fires when the capsule is tapped. Re-assigned on every configure, since
    /// the hosting view is reused across sections.
    public var onTap: (() -> Void)?

    public private(set) var presentation: Presentation = .inline

    /// Held so the section gap can be applied per header — see `setLeadsList`.
    private var topConstraint: NSLayoutConstraint?
    /// ⚠️ **The header's height must not depend on which shape it is wearing.**
    /// The two states have different type sizes, so a self-sizing header would
    /// re-measure mid-scroll and shove every row below it — the morph would
    /// jitter the whole list. One constant height, sized for the taller of the
    /// two, keeps the box still while its contents change.
    private var heightConstraint: NSLayoutConstraint?
    private var title: String?
    /// Watches the enclosing scroll view so the header decides its own shape.
    /// See `beginObservingScroll`.
    private var scrollObservation: NSKeyValueObservation?

    public init() {
        super.init(frame: .zero)
        applyConfiguration(for: presentation)
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        // Hugging horizontally so the header wraps its title rather than
        // stretching: it is sized by its label, and the space either side of it
        // is the list showing through.
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func setPillTitle(_ title: String?) {
        self.title = title
        applyConfiguration(for: presentation)
        accessibilityHint = title.map { "Scrolls to the \($0) section" }
    }

    /// Pins the header into a host: leading-aligned on the host's margins,
    /// floating clear of its top and bottom, and free to be narrower than the
    /// host is wide.
    public func pinAsHeader(in host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        let top = topAnchor.constraint(equalTo: host.topAnchor, constant: Metrics.float)
        let height = heightAnchor.constraint(equalToConstant: Self.reservedHeight(for: traitCollection))
        topConstraint = top
        heightConstraint = height
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.layoutMarginsGuide.leadingAnchor),
            top,
            height,
            bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Metrics.float),
            trailingAnchor.constraint(lessThanOrEqualTo: host.layoutMarginsGuide.trailingAnchor)
        ])
    }

    /// Whether this header opens the list or follows another section — which is
    /// the only thing that decides its top margin. See `Metrics.sectionGap`.
    ///
    /// Set on every configure, not once: header views are recycled across
    /// sections, so a view that carried the gap for "Recent" would carry it
    /// into "New" the moment it was reused.
    public func setLeadsList(_ leadsList: Bool) {
        let constant = Metrics.float + (leadsList ? 0 : Metrics.sectionGap)
        guard topConstraint?.constant != constant else { return }
        topConstraint?.constant = constant
        // The host has to re-measure: this changes the header's HEIGHT, not
        // just the pill's position inside it, and a recycled header that is
        // never asked again keeps whatever height it was dequeued with.
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    // MARK: - Deciding the shape

    /// Adopts a shape as a plain opacity crossfade: the header stays exactly
    /// where it is and one dressing dissolves into the other.
    ///
    /// One dissolve carries the background, the type size, the weight and the
    /// colour together — four properties that would otherwise need four
    /// animations agreeing on a curve, and any disagreement between them reads
    /// as the header doing something rather than becoming something.
    public func setPresentation(_ presentation: Presentation, animated: Bool = true) {
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        guard animated, window != nil else {
            return UIView.performWithoutAnimation { applyConfiguration(for: presentation) }
        }
        // ⚠️ The fade is added FIRST and everything under it is then changed
        // with animation off. Both halves matter, and the second is the one that
        // was missing: a crossfade whose contents are ALSO animating is a
        // crossfade with a slide underneath it.
        //
        // Two things slide if left alone. The header hugs its title and is
        // anchored on its leading edge, so a type-size change moves the
        // trailing edge — the capsule appears to grow out of the left margin
        // rather than fade in. And `UIButton.Configuration` animates its own
        // title change, which reveals the new text left-to-right on top of
        // that. Neither is geometry the viewer asked to watch: the header is in
        // the same place before and after, only dressed differently.
        //
        // `CATransition` rather than `UIView.transition` because it dissolves
        // the layer's RENDERED RESULT and takes no view-level animation with
        // it, so suppressing the inner animations cannot also suppress the
        // fade. Not an alpha ramp on the glass either — the house rule against
        // fading a visual effect's `alpha` is about the material sampling a
        // wrong backdrop at partial opacity, which a render-level dissolve
        // never does.
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Metrics.morphDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: Self.morphAnimationKey)
        UIView.performWithoutAnimation {
            applyConfiguration(for: presentation)
            // Settled inside the same pass, so the new width is in place before
            // the fade renders a single frame — the geometry cuts, the pixels
            // dissolve.
            superview?.layoutIfNeeded()
        }
    }

    private static let morphAnimationKey = "sectionHeaderMorph"

    /// Re-decides the shape from where this header sits in `scrollView`.
    ///
    /// **Distance to the pin line, and whether anything is above it.** A pinned
    /// header sits exactly ON that line — UIKit puts it there — and an unpinned
    /// one is somewhere below, so one subtraction answers a question that would
    /// otherwise need the section's natural geometry, which tables and
    /// compositional layouts report in two different ways and only one of them
    /// reports at all once pinning has moved the frame.
    ///
    /// ⚠️ **Touching the pin line is not the same as being HELD at it**, and the
    /// first header is where the difference shows. At rest it is already on that
    /// line — it is the first thing in the list — so a distance test alone made
    /// it a capsule before the viewer had scrolled a single point, and the
    /// inline shape was something you could only see by scrolling back up to a
    /// header that was never a title in the first place. A list resting at its
    /// top has nothing pinned; it just has a top.
    public func updatePresentation(in scrollView: UIScrollView) {
        guard let host = superview else { return }
        let pinLine = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let top = host.convert(host.bounds, to: scrollView).minY
        let isAtTheLine = top - pinLine <= Metrics.morphDistance
        // The same grace the morph gets, spent here instead for the first
        // header: a list nudged by a point or two has not started sticking.
        // Later headers reach the line only long after this is satisfied, so it
        // costs them nothing.
        let isHoldingSomethingBack = pinLine > Metrics.morphDistance
        setPresentation(isAtTheLine && isHoldingSomethingBack ? .pinned : .inline)
    }

    /// Starts watching the enclosing scroll view, so every host gets this
    /// behaviour without writing any of it.
    ///
    /// ⚠️ **KVO on `contentOffset`, not `layoutSubviews`.** A pinned header IS
    /// re-positioned every tick and would lay out; an inline one is not — its
    /// frame in content coordinates does not move while the content scrolls
    /// past it — so a layout-driven version would only ever see headers that
    /// had already pinned, and the inline half of the morph would never run.
    private func beginObservingScroll() {
        scrollObservation = nil
        guard let scrollView = enclosingScrollView() else { return }
        // `.initial` so a header dequeued mid-scroll adopts its shape on the
        // frame it appears in, rather than arriving inline over a pinned
        // position and correcting itself on the next tick.
        scrollObservation = scrollView.observe(
            \.contentOffset, options: [.initial, .new]
        ) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                // Un-animated on the very first look: adopting a shape is not a
                // change the viewer made, and a header dequeued already pinned
                // should not dissolve into place under them.
                guard let self else { return }
                if self.window == nil { self.presentation = .inline }
                self.updatePresentation(in: scrollView)
            }
        }
    }

    private func enclosingScrollView() -> UIScrollView? {
        var view: UIView? = superview
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            scrollObservation = nil
        } else {
            beginObservingScroll()
        }
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.preferredContentSizeCategory != previous?.preferredContentSizeCategory
        else { return }
        heightConstraint?.constant = Self.reservedHeight(for: traitCollection)
        applyConfiguration(for: presentation)
    }

    // MARK: - The two shapes

    private func applyConfiguration(for presentation: Presentation) {
        var configuration: UIButton.Configuration
        switch presentation {
        case .pinned:
            configuration = .glass()
            configuration.cornerStyle = .capsule
            configuration.contentInsets = Metrics.textInsets
            configuration.baseForegroundColor = .secondaryLabel
        case .inline:
            configuration = .plain()
            // No horizontal inset: a large title belongs on the list's own
            // margin, beside the content it introduces. The capsule's padding
            // is what indents the pinned shape, and watching the title step in
            // as it forms is most of what makes the morph read as one.
            configuration.contentInsets = .zero
            configuration.baseForegroundColor = .label
        }
        configuration.attributedTitle = title.flatMap { title in
            guard !title.isEmpty else { return nil }
            var attributes = AttributeContainer()
            attributes.font = Self.font(for: presentation, traits: traitCollection)
            return AttributedString(title, attributes: attributes)
        }
        self.configuration = configuration
    }

    private static func font(for presentation: Presentation, traits: UITraitCollection) -> UIFont {
        switch presentation {
        case .inline: .preferredFont(forTextStyle: .title3, compatibleWith: traits).withWeight(.bold)
        case .pinned: .preferredFont(forTextStyle: .subheadline, compatibleWith: traits).withWeight(.semibold)
        }
    }

    /// The height the header holds in BOTH shapes — the taller of the two, so
    /// neither can resize the box it lives in.
    private static func reservedHeight(for traits: UITraitCollection) -> CGFloat {
        let inline = font(for: .inline, traits: traits).lineHeight
        let pinned = font(for: .pinned, traits: traits).lineHeight
            + Metrics.textInsets.top + Metrics.textInsets.bottom
        return ceil(max(inline, pinned))
    }
}

private extension UIFont {
    /// A weight at this font's own size, keeping whatever Dynamic Type has
    /// already scaled it to — a descriptor edit, so the size is never restated.
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
