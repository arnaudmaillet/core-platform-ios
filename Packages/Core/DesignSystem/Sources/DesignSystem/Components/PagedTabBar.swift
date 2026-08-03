import UIKit

/// A floating Liquid Glass tab capsule that tracks a horizontal pager: a lens
/// slides between segments in step with the pages beneath it.
///
/// Built for the Messages inbox (All / Requests / Suggestions) and reused
/// unchanged by the For You grid (Activity / Gallery / Short). It knows nothing
/// about either — it takes titles and reports an index, so a third host is a
/// `titles` array and two closures.
///
/// **Anatomy.** A full-width capsule of `UIGlassEffect` inset by the standard
/// margin, its own soft shadow, and a tinted overlay marking the active
/// segment. The capsule floats and has no hairline, so content scrolls
/// *beneath* it and is seen through the glass. Segments share the width
/// equally, so the bar reads the same on every screen.
///
/// **A control, not a view.** The bar is a `UIControl` carrying
/// `selectedIndex` and announcing `.valueChanged`, and each segment is a
/// `UIButton` sending `.primaryActionTriggered` — so the owner wires this the
/// way it would wire a `UISegmentedControl`, and UIKit owns the whole touch
/// state machine: what counts as a press, when a drag outside cancels it, when
/// the highlight comes back. Pressed appearance is expressed in
/// `configurationUpdateHandler`, which is where UIKit asks for it; there is no
/// `isHighlighted` observer and no animation of ours. The container's own
/// pressed feedback is the system's, via `UIGlassEffect.isInteractive`.
///
/// **ONE material, not two.** The lens is a plain tinted `UIView`
/// (`label` at 18% — a darkening in light mode, a lightening in dark), NOT a
/// second `UIVisualEffectView`. That is the whole trick: an earlier build put a
/// glass lens inside a glass capsule and the lens lost its edge entirely — the
/// selected segment stopped reading as selected, which is the one thing this
/// control exists to say. A tint has nothing to refract, so it separates
/// cleanly from the glass behind it at any position. It also honours the house
/// rule `GlassSegmentRow` documents, which the old blur-plus-glass pairing had
/// to argue its way around.
///
/// `UIGlassContainerEffect` is NOT the backdrop to reach for: it is a
/// *grouping* effect for sibling glass elements that should merge, and used as
/// the capsule's own effect it renders no backdrop whatsoever — content behind
/// the bar collides with the segment titles at full contrast.
///
/// ⚠️ **Semantic colours do not survive inside the glass content view.** The
/// badge's `.systemBackground` text resolved to WHITE in dark mode, on a badge
/// whose fill had correctly resolved to white — an invisible count, on a
/// control whose whole job is to show counts. `BadgeView` therefore states its
/// text colour as an explicit dynamic colour. Anything added inside this
/// capsule needs checking in BOTH appearances, not reasoned about.
///
/// **Overflow.** The segments live in a scroll view. Below the capsule's width
/// ceiling it never scrolls and is inert in every sense; past it — a fourth
/// segment, a three-digit badge, a large Dynamic Type size — the capsule stops
/// growing and the strip scrolls, with the active segment kept in view. The
/// margin was thin without it: three segments with two badges need 331pt of the
/// 343pt a 375pt screen offers at XL text.
///
/// **Tracking.** `setProgress` takes the pager's *fractional* page position
/// and interpolates the lens's frame between the two neighbouring segments
/// while crossfading each segment's regular/semibold label pair. Nothing
/// snaps: a tap animates the pager, which reports progress every frame, so
/// taps and swipes drive the header through exactly the same path. The label
/// pair exists so selection can change weight without re-measuring — segment
/// widths are pinned to their SEMIBOLD size up front, the reflow trap
/// `GlassSegmentRow` calls out.
///
/// The lens tracks progress LINEARLY and rigidly, and there is no physics of
/// any kind in this file. Elasticity has now been built and removed TWICE — a
/// spring-driven version in 2026-07, and a velocity-derived stretch after it —
/// so treat a third attempt as a decision to be made deliberately rather than a
/// gap to be filled. Both are recorded in [[messages-inbox-paged]]. If it ever
/// does return: the lens must be driven by its `frame`, never a
/// `CGAffineTransform`, which scales the rendered corner radius and degrades
/// the capsule into an ellipse; and any decay must have a tick source that
/// outlives the last progress change, because `setProgress` early-returns on an
/// unchanged position and will otherwise freeze the effect mid-stretch.
public final class PagedTabBar: UIControl {
    private enum Metrics {
        /// The floating capsule's own height.
        static let capsuleHeight: CGFloat = 42
        static let topMargin: CGFloat = 4
        static let bottomMargin: CGFloat = 8
        /// Breathing room between the capsule's edge and the first segment.
        static let capsulePadding: CGFloat = 5
        /// Inset of the lens inside the capsule.
        static let lensInset: CGFloat = 4
        static let interSegmentSpacing: CGFloat = 2
    }

    /// Total height the container reserves as safe area, margins included.
    ///
    /// `nonisolated` because owners read it to size the bar and to set
    /// `additionalSafeAreaInsets.top`, often from a nested constants type that
    /// carries no actor isolation of its own — a `UIView` subclass's statics
    /// are `@MainActor` by inference and would be unreachable from there. The
    /// same reason `InlineFilterTrayView.height` states it.
    public nonisolated static let height: CGFloat =
        Metrics.capsuleHeight + Metrics.topMargin + Metrics.bottomMargin

    /// The segment the bar is reporting — updated by taps AND by the pages
    /// moving under it, so it is never stale. Reading it is how a
    /// `.valueChanged` handler learns WHICH segment — the same shape
    /// `UISegmentedControl` has, so the owner registers a `UIAction` rather
    /// than being handed a closure to store.
    public private(set) var selectedIndex: Int = 0
    /// A drag on the capsule itself, as a fractional page position. Fires every
    /// frame of the finger; the owner scrubs the pager to it.
    public var onScrub: ((CGFloat) -> Void)?
    /// That drag ended, with its velocity in pages per second, so the owner can
    /// let a flick carry to the next page instead of snapping back.
    public var onScrubEnd: ((CGFloat) -> Void)?

    private let titles: [String]
    /// Carries the shadow; the capsule itself clips to its corner radius,
    /// which would clip a shadow set on the same layer.
    private let shadowHost = UIView()
    private let capsule = UIVisualEffectView(effect: nil)
    /// Scrolls the segments when they out-measure the capsule. Below that
    /// width it never scrolls and is invisible in every sense.
    private let scroller = UIScrollView()
    /// The scroll view's content: the lens and the row, in one coordinate
    /// space. The lens lives HERE rather than in the capsule so it travels with
    /// the segments for free — a lens pinned outside would need the content
    /// offset subtracted out of it on every frame of both gestures.
    private let content = UIView()
    /// The active-segment marker. A tinted overlay, NOT a second material —
    /// see the type comment on why glass-inside-glass cost the lens its edge.
    private let lens = UIView()
    private let row = UIStackView()
    private var segments: [SegmentView] = []
    private var progress: CGFloat = 0
    private var scrubPan: UIPanGestureRecognizer!
    /// Where `progress` stood when the current capsule drag began.
    private var scrubOrigin: CGFloat = 0

    public init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)

        shadowHost.layer.shadowColor = UIColor.black.cgColor
        shadowHost.layer.shadowOpacity = 0.12
        shadowHost.layer.shadowRadius = 10
        shadowHost.layer.shadowOffset = CGSize(width: 0, height: 3)
        // Full width, standard margins — the capsule is a bar, not a badge, so
        // it reads the same on every screen instead of growing and shrinking
        // with whatever the segment titles happen to measure.
        shadowHost.constrain(in: self) { parent in
            shadowHost.topAnchor.constraint(equalTo: parent.topAnchor, constant: Metrics.topMargin)
            shadowHost.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Metrics.bottomMargin)
            shadowHost.leadingAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: Spacing.lg
            )
            shadowHost.trailingAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.lg
            )
        }

        capsule.clipsToBounds = true
        capsule.pin(to: shadowHost)

        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        // Segments are buttons: without this the scroll view swallows the first
        // touch and a tap only registers after a perceptible delay.
        scroller.delaysContentTouches = false
        scroller.pin(to: capsule.contentView)

        content.constrain(in: scroller) { _ in
            content.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor)
            content.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor)
            content.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor)
            content.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor)
            // The scroll view has no intrinsic size, so the content's height is
            // tied to the frame — this axis must never scroll.
            content.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor)
        }

        // The lens goes in before the row so it sits behind the labels; it is
        // frame-driven (not constrained) because it has to land on fractional
        // positions between two segments every frame.
        content.addSubview(lens)
        lens.clipsToBounds = true
        lens.isUserInteractionEnabled = false
        lens.backgroundColor = Self.lensTint

        row.axis = .horizontal
        row.spacing = Metrics.interSegmentSpacing
        row.alignment = .fill
        // Equal slots, so the bar looks balanced at any width and a short title
        // gets the same target as a long one. Segment widths are minimums
        // (`>=`) rather than exact, which is what lets this distribute the
        // slack — and what still lets the row out-measure the capsule and
        // scroll when the titles genuinely need more room than the screen has.
        row.distribution = .fillEqually
        buildSegments()
        row.constrain(in: content) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Metrics.capsulePadding)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.capsulePadding)
        }

        // Fill the capsule, and overflow it when the titles demand more. Only a
        // `>=` — the row's own minimums push `content` wider than this when
        // they have to, and the scroll view takes it from there. An `==` would
        // forbid that and clip instead.
        content.widthAnchor.constraint(
            greaterThanOrEqualTo: scroller.frameLayoutGuide.widthAnchor
        ).isActive = true

        // Grab anywhere. The capsule is one physical object, so dragging it
        // should move the pages whether the finger happens to land on a title,
        // on a badge, or on the glass between them.
        scrubPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrub))
        scrubPan.delegate = self
        capsule.contentView.addGestureRecognizer(scrubPan)

        // The whole capsule reads as one tab bar to VoiceOver; each segment is
        // a button reporting its own selected state.
        accessibilityContainerType = .semanticGroup
        row.accessibilityTraits = .tabBar

        applyProgress()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    /// Materialized in-window, never in init: creating a real effect off
    /// screen stalls the render server on headless CI simulators (the same
    /// rule `ChatInputBar` and `SnapGlassCardView` follow).
    private func materializeEffects() {
        guard window != nil else { return }
        if capsule.effect == nil {
            let glass = UIGlassEffect(style: .regular)
            // The system's own press response for glass: the material flexes
            // under a touch instead of sitting inert. This is the whole of the
            // container's pressed feedback — there is no scale math or spring
            // of ours anywhere near it.
            glass.isInteractive = true
            capsule.effect = glass
        }
    }

    /// The active segment's fill. Adaptive by construction: `label` is near
    /// black in light mode and near white in dark, so one constant reads as a
    /// darkening in one and a lightening in the other, over a backdrop that is
    /// itself taking its cue from the content behind it.
    ///
    /// 0.18 rather than 0.12, chosen by comparison over scrolled list rows —
    /// which is the hard case, because the glass backdrop passes more of the
    /// content through than the thin material did. At 0.12 the pill reads as
    /// soft shading; at 0.18 it is unambiguous and still subtle.
    /// `.quaternarySystemFill` was fainter than either and was discarded.
    private static let lensTint = UIColor.label.withAlphaComponent(0.18)

    public override func layoutSubviews() {
        super.layoutSubviews()
        capsule.layer.cornerRadius = capsule.bounds.height / 2
        capsule.layer.cornerCurve = .continuous
        shadowHost.layer.shadowPath = UIBezierPath(
            roundedRect: shadowHost.bounds,
            cornerRadius: shadowHost.bounds.height / 2
        ).cgPath
        applyProgress()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        materializeEffects()
    }

    // MARK: - Driven state

    /// The pager's fractional page position. Called every frame of a drag and
    /// every frame of a tap-driven scroll animation.
    public func setProgress(_ progress: CGFloat) {
        guard progress != self.progress else { return }
        self.progress = progress
        // The value tracks the pages, not just taps. Without this a swipe would
        // leave `selectedIndex` stale, and the next tap on the segment the
        // viewer had swiped away from would be read as "no change" and do
        // nothing. Silent — the pages are already where this says they are, so
        // announcing it would tell the owner something it just told us.
        selectedIndex = Int(progress.rounded())
        applyProgress()
    }

    /// The count beside a segment's title; 0 hides it.
    public func setBadge(_ count: Int, at index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].setBadge(count)
        // A badge changes the segment's pinned width, so the lens has to
        // re-derive its geometry from the new frames.
        setNeedsLayout()
        layoutIfNeeded()
        applyProgress()
    }

    /// Re-asserts the bar's appearance after an interactive transition.
    ///
    /// Interactive transitions rasterise and re-parent the views they carry,
    /// and glass-hosted controls do not always come back whole — the observed
    /// failure elsewhere in this app is a capsule that returns at full width
    /// with only the selected title drawn. Nothing in our own code clears them,
    /// so the repair cannot be "stop doing that"; it has to be "rebuild the
    /// appearance once the transition is over". Idempotent and cheap, so hosts
    /// call it on every completion including the ones that were fine.
    ///
    /// A plain method rather than a `TransitionRestorable` conformance: that
    /// protocol lives in `PostGrid`, which depends on this module and cannot be
    /// depended on from here.
    public func restoreAfterTransition() {
        alpha = 1
        isHidden = false
        transform = .identity
        for view in [shadowHost, capsule, capsule.contentView, scroller, content, row] {
            view.alpha = 1
            view.isHidden = false
            view.transform = .identity
        }
        for segment in segments {
            segment.alpha = 1
            segment.isHidden = false
            segment.transform = .identity
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Chooses a segment exactly as a tap would, `.valueChanged` and all — so
    /// a deep link or a scripted QA run drives the same path a finger does
    /// instead of reaching past the bar to the pager and leaving the two to
    /// agree by luck.
    ///
    /// There is deliberately no "silent" variant. The lens is driven by
    /// `setProgress` off the pager's position, so a caller that wants to move
    /// the bar without moving the pages is describing a state this control
    /// cannot be in.
    public func select(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        selectSegment(index)
    }

    /// A segment was chosen. Publishes through `.valueChanged` rather than a
    /// stored closure, so the owner wires this the way it would wire any
    /// system control.
    private func selectSegment(_ index: Int) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        sendActions(for: .valueChanged)
    }

    // MARK: - Grab

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === scrubPan else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        // When the strip itself has somewhere to scroll, the finger belongs to
        // it — moving the tabs and moving the pages at once would be two
        // answers to one gesture.
        guard scroller.contentSize.width <= scroller.bounds.width + 0.5 else { return false }
        // Horizontal intent only. A vertical drag that starts on the bar is
        // someone reaching for the content underneath it.
        let velocity = scrubPan.velocity(in: capsule)
        return abs(velocity.x) > abs(velocity.y)
    }

    /// Translates a drag on the capsule into pages.
    ///
    /// One segment's width dragged = one page, so the lens keeps pace with the
    /// finger rather than sliding at some other rate.
    ///
    /// **The sign follows the LENS, not the pages.** Dragging left moves the
    /// selection left: the capsule behaves like a strip of tabs being slid
    /// under the finger, which is what grabbing a physical object implies.
    /// That is deliberately the OPPOSITE of dragging the page content, where
    /// pulling left brings the next page in from the right — the two gestures
    /// act on different objects, and each follows the one being touched.
    @objc private func handleScrub(_ pan: UIPanGestureRecognizer) {
        guard segments.count > 1 else { return }
        let slot = max(1, segments[0].bounds.width + Metrics.interSegmentSpacing)
        switch pan.state {
        case .began:
            scrubOrigin = progress
        case .changed:
            let delta = pan.translation(in: capsule).x / slot
            onScrub?(scrubOrigin + delta)
        case .ended, .cancelled, .failed:
            onScrubEnd?(pan.velocity(in: capsule).x / slot)
        default:
            break
        }
    }

    private func buildSegments() {
        segments = titles.enumerated().map { index, title in
            let segment = SegmentView(title: title)
            segment.addAction(
                UIAction { [weak self] _ in self?.selectSegment(index) },
                // `.primaryActionTriggered` now that the segment is a real
                // `UIButton` — UIButton synthesizes it, where the bare
                // `UIControl` this used to be never fired it at all.
                for: .primaryActionTriggered
            )
            row.addArrangedSubview(segment)
            return segment
        }
    }

    // MARK: - Interpolation

    private func applyProgress() {
        guard !segments.isEmpty, row.bounds.width > 0, row.bounds.height > 0 else { return }
        let clamped = min(max(progress, 0), CGFloat(segments.count - 1))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, segments.count - 1)
        let t = clamped - CGFloat(lower)

        // Weight/tint crossfade: each segment is fully "selected" at its own
        // index and fully plain a page away, so a half-way drag shows both
        // neighbours at half strength — the same readout as the lens's frame.
        for (index, segment) in segments.enumerated() {
            segment.setSelectionStrength(max(0, 1 - abs(clamped - CGFloat(index))))
        }

        let from = lensFrame(for: lower)
        let to = lensFrame(for: upper)
        let rect = CGRect(
            x: from.minX + (to.minX - from.minX) * t,
            y: from.minY,
            width: from.width + (to.width - from.width) * t,
            height: from.height
        )

        lens.frame = rect
        lens.layer.cornerRadius = lens.bounds.height / 2
        lens.layer.cornerCurve = .continuous
        keepLensVisible()
    }

    /// Follows the lens with the scroll offset when the row is wider than the
    /// capsule — the "active tab scrolls itself into view" half of the pattern.
    ///
    /// `scrollRectToVisible` unanimated is exactly right here: it scrolls the
    /// MINIMUM distance needed and no-ops when the rect is already visible, so
    /// the bar sits still through the middle of a drag and only creeps at the
    /// ends. Animating instead would queue a 0.3s animation on every one of the
    /// ~18 frames a page change emits, and they would fight each other.
    ///
    /// Skipped while the viewer is scrolling the bar by hand — otherwise their
    /// own drag would be yanked back to the selection under their finger.
    private func keepLensVisible() {
        guard scroller.contentSize.width > scroller.bounds.width,
              !scroller.isDragging, !scroller.isDecelerating
        else { return }
        scroller.scrollRectToVisible(
            lens.frame.insetBy(dx: -Metrics.capsulePadding, dy: 0), animated: false
        )
    }

    /// Built by hand rather than with `insetBy`: insetting a rect past its own
    /// size yields `CGRect.null`, whose infinite origin turns the frame
    /// interpolation into NaN and takes CALayer down with it. Segments start
    /// at zero height, so that path is not hypothetical.
    ///
    /// Coordinates are the SCROLL CONTENT's, not the capsule's — `row.frame` is
    /// already expressed in `content`, and the lens is a sibling there, so the
    /// arithmetic is unchanged by the scroll view and no content offset has to
    /// be subtracted anywhere.
    private func lensFrame(for index: Int) -> CGRect {
        let segment = segments[index].frame
        return CGRect(
            x: row.frame.minX + segment.minX,
            y: row.frame.minY + segment.minY + Metrics.lensInset,
            width: segment.width,
            height: max(0, segment.height - Metrics.lensInset * 2)
        )
    }
}

/// Conformance only — the policy is an `override` in the class body, because
/// `UIView` already declares `gestureRecognizerShouldBegin(_:)` and Swift will
/// not let an extension override it.
extension PagedTabBar: UIGestureRecognizerDelegate {}

// MARK: - Segment

/// One segment: a stacked pair of labels (regular and semibold) that crossfade,
/// plus an optional count badge. Its width is pinned to the SEMIBOLD
/// measurement so selection can never reflow the row.
private final class SegmentView: UIButton {
    /// Titles scale with Dynamic Type up to here, then stop — four segments
    /// have to stay side by side in one fixed-height capsule.
    static let maximumTitlePointSize: CGFloat = 19

    private let plainLabel = UILabel()
    private let boldLabel = UILabel()
    private let badge = BadgeView()
    private let content = UIStackView()
    private let title: String
    private var pinnedWidth: NSLayoutConstraint!

    init(title: String) {
        self.title = title
        super.init(frame: .zero)

        for (label, weight) in [(plainLabel, UIFont.Weight.regular), (boldLabel, .semibold)] {
            label.text = title
            label.font = .preferredFont(forTextStyle: .subheadline, weight: weight, maximumPointSize: SegmentView.maximumTitlePointSize)
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.isUserInteractionEnabled = false
        }
        plainLabel.textColor = .secondaryLabel
        boldLabel.textColor = .label
        boldLabel.alpha = 0

        // The SEMIBOLD label defines the geometry (it is the wider of the
        // pair); the regular one is centred on top of it and only ever
        // crossfades, so neither weight can move the other's layout.
        content.addArrangedSubview(boldLabel)
        content.addArrangedSubview(badge)
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Spacing.xs
        content.isUserInteractionEnabled = false
        content.constrain(in: self) { parent in
            content.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            content.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        plainLabel.constrain(in: self) { _ in
            plainLabel.centerXAnchor.constraint(equalTo: boldLabel.centerXAnchor)
            plainLabel.centerYAnchor.constraint(equalTo: boldLabel.centerYAnchor)
        }

        badge.isHidden = true
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button

        // A real button with a real configuration, so UIKit owns the control
        // state machine: when a touch is a press, when it is cancelled, when a
        // drag outside un-highlights. Pressed feedback lives on the CONTENT,
        // never on the lens — the lens belongs to the selection, not the touch.
        //
        // `.plain()` carries no title of its own: the regular/semibold pair
        // above is what renders, because selection here is FRACTIONAL and a
        // configuration title can only be one weight at a time. The handler is
        // UIKit's designated place to express appearance per state, which is
        // what replaces the hand-rolled `isHighlighted` observer this had.
        configuration = .plain()
        configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            let dimmed = button.isHighlighted ? 0.55 : 1
            self.content.alpha = dimmed
            self.plainLabel.alpha = dimmed * (1 - self.strength)
        }

        // A MINIMUM, not an exact width: `fillEqually` on the row hands every
        // segment the same slot, and this only states how narrow that slot is
        // allowed to get before the row has to overflow and scroll.
        pinnedWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        pinnedWidth.isActive = true
        updatePinnedWidth()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryChanged),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var strength: CGFloat = 0

    /// 1 = fully selected, 0 = fully unselected, fractions mid-drag.
    func setSelectionStrength(_ strength: CGFloat) {
        self.strength = strength
        boldLabel.alpha = strength
        plainLabel.alpha = 1 - strength
        badge.setSelectionStrength(strength)
        let selected = strength > 0.5
        if selected != accessibilityTraits.contains(.selected) {
            accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }

    func setBadge(_ count: Int) {
        badge.setCount(count)
        badge.isHidden = count == 0
        // The badge is a sibling in the stack, so its own hidden state is what
        // the accessibility label has to carry — VoiceOver reads the segment as
        // one element, and a count nobody announces is a count nobody gets.
        accessibilityValue = count == 0 ? nil : "\(count) new"
        updatePinnedWidth()
    }

    @objc private func contentSizeCategoryChanged() {
        updatePinnedWidth()
    }

    /// Width = the semibold title plus the badge (when shown) plus breathing
    /// room, so the lens has somewhere to sit and the row never reflows.
    private func updatePinnedWidth() {
        let bold = UIFont.preferredFont(forTextStyle: .subheadline, weight: .semibold, maximumPointSize: Self.maximumTitlePointSize)
        var width = ceil((title as NSString).size(withAttributes: [.font: bold]).width) + Spacing.lg
        if !badge.isHidden {
            width += badge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + Spacing.xs
        }
        pinnedWidth.constant = width
    }
}

// MARK: - Badge

/// The pending count beside a segment title: a filled capsule that follows the
/// segment's own selection strength, so it brightens with its label.
private final class BadgeView: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        label.font = .preferredFont(forTextStyle: .caption2, weight: .semibold, maximumPointSize: 15)
        label.adjustsFontForContentSizeCategory = true
        // `.systemBackground` does NOT survive inside a `UIGlassEffect` content
        // view — it resolved to white in dark mode, on a badge whose fill had
        // correctly resolved to white, erasing the count. An explicit dynamic
        // colour carries the same intent (the inverse of `.label`) in values
        // the effect can't reinterpret.
        label.textColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.06, alpha: 1)
                : UIColor(white: 1, alpha: 1)
        }
        label.textAlignment = .center
        label.pin(to: self, insets: NSDirectionalEdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5))
        backgroundColor = .secondaryLabel
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func setCount(_ count: Int) {
        // Past 99 the capsule would out-measure its own segment title.
        label.text = count > 99 ? "99+" : String(count)
        invalidateIntrinsicContentSize()
    }

    func setSelectionStrength(_ strength: CGFloat) {
        backgroundColor = strength > 0.5 ? .label : .secondaryLabel
    }
}

private extension UIFont {
    /// Scales with Dynamic Type but stops growing past `maximumPointSize`.
    ///
    /// The capsule is fixed chrome holding up to four segments side by side —
    /// at accessibility sizes unbounded scaling makes the titles collide and
    /// clip off the edge. Capping is what the system itself does for tab bar
    /// item titles: the row stays legible and stays a row.
    static func preferredFont(
        forTextStyle style: TextStyle,
        weight: Weight,
        maximumPointSize: CGFloat
    ) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: style)
        let base = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
        return metrics.scaledFont(for: base, maximumPointSize: maximumPointSize)
    }
}
