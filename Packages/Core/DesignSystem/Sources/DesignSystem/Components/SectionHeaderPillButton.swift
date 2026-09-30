import UIKit

/// Every pinning list's section header, in the two shapes a section header
/// has: a large bold title while it sits in the flow, and a floating glass
/// capsule once it pins to the top.
///
/// **Why two shapes.** In the flow a header is *typography* — it introduces the
/// rows under it and wants the weight and size that says so. Pinned, it is
/// *chrome* — it is floating over content it no longer introduces, and a large
/// title parked over scrolling rows reads as a title that failed to scroll
/// away. The system's own large-title navigation bars make exactly this move,
/// and a list whose headers stayed one size looked, next to them, like a screen
/// that had forgotten to.
///
/// **The same title in both shapes (2026-09-30).** What the header SAYS is a
/// `SectionTitleView` — the app's one section title, `New 8` with the count
/// as secondary text — drawn `.standard` in the flow and `.compact` in the
/// capsule. In the flow it is therefore indistinguishable from every other
/// section title in the app: same type, same colours, same gaps, and the same
/// `SectionTitleView.Metrics.surfaceInset` from the surface's edge. The
/// capsule forms AROUND that line — its leading edge stays on it and the
/// title steps in by the capsule's padding, which is most of what makes the
/// morph read as one.
///
/// **A real `UIButton` on `UIButton.Configuration.glass()`** in the pinned
/// state, not a `UIVisualEffectView` with a tap recognizer bolted on. That is
/// what buys the native Liquid Glass press behaviour — the deform-and-settle
/// spring, the highlight, the accessibility treatment of a control — none of
/// which a recognizer over an effect view would produce. The configuration
/// draws the capsule and nothing else: the title is a SUBVIEW over it.
///
/// ⚠️ Not the configuration's title: on glass a configuration's content is
/// rendered VIBRANT, and a two-colour title (a label title, a secondary
/// count) is what vibrancy flattens — the hearts and gems that came out black
/// were exactly that (`platter-flattens-label-alpha`). The count badge this
/// header used to carry lived as a subview for the same reason.
///
/// It lives here rather than in any one feature because the inbox's two
/// tables, the inbox search's and the search screen's collection views, and
/// For You's pushed Following and Friends lists all need the same header. All
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
        /// Above the pill: it floats clear of the top of the band it pins in.
        ///
        /// ⚠️ The SAME for every header, first or not. A plain table PINS its
        /// headers and a pinned header carries its top margin with it — a gap
        /// spent above the pill hung a second section's capsule lower than the
        /// first's for as long as both were stuck to the top (measured on the
        /// inbox: `pillTop=8` for section 0, `24` for section 1). The
        /// separation between sections is the host's, spent at the END of the
        /// section above (`sectionGap(traits:)`).
        public static let float = Spacing.sm
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

    /// The pill's distance from its host's leading edge — restated from the
    /// surface on every host layout (`alignToSurface`).
    private var leadingConstraint: NSLayoutConstraint?
    /// Stands the inline title's line `Spacing.sectionTitle` over the first
    /// row — see `bottomMargin`.
    private var bottomConstraint: NSLayoutConstraint?
    /// ⚠️ **The header's height must not depend on which shape it is wearing.**
    /// The two states have different type sizes, so a self-sizing header would
    /// re-measure mid-scroll and shove every row below it — the morph would
    /// jitter the whole list. One constant height, sized for the taller of the
    /// two, keeps the box still while its contents change.
    private var heightConstraint: NSLayoutConstraint?
    /// What the header says, drawn by `titleView` in both shapes.
    private var content = SectionTitleView.Content(title: nil)
    private let titleView = SectionTitleView(embeddedStyle: .standard)
    /// Watches the enclosing scroll view so the header decides its own shape.
    /// See `beginObservingScroll`.
    private var scrollObservation: NSKeyValueObservation?

    public init() {
        super.init(frame: .zero)
        applyConfiguration(for: presentation)
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        addSubview(titleView)
        // Hugging horizontally so the header wraps its title rather than
        // stretching: it is sized by its title (`intrinsicContentSize`), and
        // the space either side of it is the list showing through.
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func setPillTitle(_ title: String?) {
        content.title = title
        applyContent()
        accessibilityHint = title.map { "Scrolls to the \($0) section" }
    }

    /// The count after the title — `New 8`, in the secondary colour. Zero (the
    /// default) draws none. Set on every configure, like the title: header
    /// views are recycled across sections.
    public func setCount(_ count: Int) {
        let count = max(0, count)
        guard count != self.count else { return }
        self.count = count
        content = SectionTitleView.Content(title: content.title, newCount: count)
        applyContent()
    }

    /// The count after the title, zero while none shows.
    public private(set) var count = 0

    /// The title shown.
    public var title: String? { content.title }

    private func applyContent() {
        titleView.content = content
        // The button is the accessibility element (its subviews are not
        // traversed): "New, 8 new, button".
        accessibilityLabel = content.title
        accessibilityValue = content.countAccessibilityValue
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    /// Pins the header into a host: its leading edge on the surface's title
    /// line, floating clear of the host's top, and free to be narrower than
    /// the host is wide.
    public func pinAsHeader(in host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        let leading = leadingAnchor.constraint(
            equalTo: host.leadingAnchor, constant: SectionTitleView.Metrics.surfaceInset
        )
        let top = topAnchor.constraint(equalTo: host.topAnchor, constant: Metrics.float)
        let bottom = host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: bottomMargin)
        let height = heightAnchor.constraint(equalToConstant: Self.reservedHeight(for: traitCollection))
        leadingConstraint = leading
        bottomConstraint = bottom
        heightConstraint = height
        NSLayoutConstraint.activate([
            leading,
            top,
            height,
            bottom,
            trailingAnchor.constraint(
                lessThanOrEqualTo: host.trailingAnchor, constant: -SectionTitleView.Metrics.surfaceInset
            )
        ])
    }

    /// Restates the pill's leading edge from where its host sits on its
    /// surface, so the title stands `SectionTitleView.Metrics.surfaceInset`
    /// from the surface's edge whether the host is laid edge to edge (a
    /// table's header) or inside a section's content insets (For You's
    /// lists). Every host calls it from its `layoutSubviews`, before `super`.
    public func alignToSurface() {
        guard let host = superview else { return }
        let inset = SectionTitleView.surfaceInsets(of: host).leading
        if leadingConstraint?.constant != inset { leadingConstraint?.constant = inset }
    }

    /// Where the inline title's line stands from the header's top: the float
    /// over the pill, then the air the pill's reserved height leaves above a
    /// title it centres. What a list counts its section gap from.
    public static func inlineTitleTop(traits: UITraitCollection) -> CGFloat {
        Metrics.float + inlineTitleAir(traits: traits)
    }

    /// What a host leaves between a section's last row and the NEXT header —
    /// a table's footer, a section's bottom inset, a list's header top
    /// padding: `Spacing.section` from that row to the next title's LINE,
    /// less what the header holds above its line (`inlineTitleTop`). The app's
    /// one section gap (2026-09-30), the same distance every other section
    /// title keeps under the section above it.
    public static func sectionGap(traits: UITraitCollection) -> CGFloat {
        max(0, (Spacing.section - inlineTitleTop(traits: traits)).rounded())
    }

    /// The air above (and below) the inline title inside the pill's reserved
    /// height.
    private static func inlineTitleAir(traits: UITraitCollection) -> CGFloat {
        max(0, (reservedHeight(for: traits) - font(for: .inline, traits: traits).lineHeight) / 2)
    }

    /// Under the pill: what stands the inline title's LINE `Spacing.sectionTitle`
    /// over the section's first row — the distance every section title in the
    /// app keeps over its content. Only the header's bottom margin carries
    /// it: the pill hangs from the header's TOP, so the pinned capsule stands
    /// where it always did.
    private var bottomMargin: CGFloat {
        max(0, (Spacing.sectionTitle - Self.inlineTitleAir(traits: traitCollection)).rounded())
    }

    private func applyBottomMargin() {
        let constant = bottomMargin
        guard bottomConstraint?.constant != constant else { return }
        bottomConstraint?.constant = constant
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
            return UIView.performWithoutAnimation {
                applyConfiguration(for: presentation)
                superview?.layoutIfNeeded()
            }
        }
        // ⚠️ The fade is added FIRST and everything under it is then changed
        // with animation off. Both halves matter, and the second is the one that
        // was missing: a crossfade whose contents are ALSO animating is a
        // crossfade with a slide underneath it.
        //
        // The header hugs its title and is anchored on its leading edge, so a
        // type-size change moves the trailing edge — left to animate, the
        // capsule appears to grow out of the left margin rather than fade in,
        // and the title's frames slide inside it. Neither is geometry the
        // viewer asked to watch: the header is in the same place before and
        // after, only dressed differently.
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
    public func updatePresentation(in scrollView: UIScrollView, animated: Bool = true) {
        guard let host = superview else { return }
        let pinLine = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let top = host.convert(host.bounds, to: scrollView).minY
        let isAtTheLine = top - pinLine <= Metrics.morphDistance
        // The same grace the morph gets, spent here instead for the first
        // header: a list nudged by a point or two has not started sticking.
        // Later headers reach the line only long after this is satisfied, so it
        // costs them nothing.
        let isHoldingSomethingBack = pinLine > Metrics.morphDistance
        setPresentation(isAtTheLine && isHoldingSomethingBack ? .pinned : .inline, animated: animated)
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
        hasSettledOnce = false
        scrollObservation = scrollView.observe(
            \.contentOffset, options: [.initial, .new]
        ) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // ⚠️ DEFERRED BY ONE TURN OF THE RUN LOOP, and it is the whole
                // fix for a header that flickered into a title mid-scroll.
                //
                // `contentOffset` is written BEFORE the collection view lays
                // out, so at the moment this fires a pinned header still has
                // the frame of the previous tick. Scrolling up, that frame is
                // one tick's travel BELOW the new pin line — and a fast flick
                // moves more than `morphDistance` in one tick, so the header
                // read as "off the line", dissolved into a title, and dissolved
                // back once the layout pass re-pinned it. A shape that flips
                // for one frame in the middle of a scroll is exactly the
                // "header doing something" the crossfade exists to avoid.
                //
                // By the next turn the layout pass has run and every frame is
                // consistent; a scroll tick never arrives in between, since
                // the display link that drives it is itself a run-loop source.
                // One evaluation per tick, whatever the number of writes.
                guard !self.hasPendingPresentationUpdate else { return }
                self.hasPendingPresentationUpdate = true
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    self.hasPendingPresentationUpdate = false
                    // Un-animated on the very first look: adopting a shape is
                    // not a change the viewer made, and a header dequeued
                    // already pinned should not dissolve into place under
                    // them.
                    let animated = self.hasSettledOnce
                    self.hasSettledOnce = true
                    self.updatePresentation(in: scrollView, animated: animated)
                }
            }
        }
    }

    private var hasPendingPresentationUpdate = false
    private var hasSettledOnce = false

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
            // The surface is known now.
            superview?.setNeedsLayout()
        }
    }

    // MARK: - Sizing

    /// The title's run plus the shape's padding, at the reserved height — what
    /// the capsule wraps and what the inline title occupies.
    public override var intrinsicContentSize: CGSize {
        let insets = Self.contentInsets(for: presentation)
        return CGSize(
            width: ceil(titleView.intrinsicContentSize.width + insets.leading + insets.trailing),
            height: Self.reservedHeight(for: traitCollection)
        )
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let insets = Self.contentInsets(for: presentation)
        titleView.frame = CGRect(
            x: insets.leading, y: 0,
            width: max(0, bounds.width - insets.leading - insets.trailing), height: bounds.height
        )
        // Over whatever the configuration draws — the glass is a background
        // UIKit may re-insert.
        bringSubviewToFront(titleView)
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.preferredContentSizeCategory != previous?.preferredContentSizeCategory
        else { return }
        heightConstraint?.constant = Self.reservedHeight(for: traitCollection)
        applyBottomMargin()
        applyConfiguration(for: presentation)
    }

    // MARK: - The two shapes

    private func applyConfiguration(for presentation: Presentation) {
        var configuration: UIButton.Configuration
        switch presentation {
        case .pinned:
            configuration = .glass()
            configuration.cornerStyle = .capsule
        case .inline:
            configuration = .plain()
        }
        // The capsule and nothing in it: the title is `titleView`.
        configuration.contentInsets = .zero
        self.configuration = configuration
        titleView.style = presentation == .pinned ? .compact : .standard
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The title's distance from the button's edges: none inline — the title
    /// IS the section title, on the surface's title line — and the capsule's
    /// padding pinned, which is what steps the title in as the capsule forms.
    private static func contentInsets(for presentation: Presentation) -> NSDirectionalEdgeInsets {
        switch presentation {
        case .inline: .zero
        case .pinned: Metrics.textInsets
        }
    }

    private static func font(for presentation: Presentation, traits: UITraitCollection) -> UIFont {
        SectionTitleView.titleFont(presentation == .pinned ? .compact : .standard, traits: traits)
    }

    /// The height the header holds in BOTH shapes — the taller of the two, so
    /// neither can resize the box it lives in.
    private static func reservedHeight(for traits: UITraitCollection) -> CGFloat {
        let inline = font(for: .inline, traits: traits).lineHeight
        let pinned = font(for: .pinned, traits: traits).lineHeight
            + Metrics.textInsets.top + Metrics.textInsets.bottom
        return ceil(max(inline, pinned))
    }

    #if DEBUG
    /// The title this header draws — the app's one section title.
    public var debugTitleView: SectionTitleView { titleView }
    #endif
}
