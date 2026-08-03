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
    /// Where the bar is being hosted, which decides its metrics and whether it
    /// carries a material of its own.
    ///
    /// Not a cosmetic switch: a navigation bar's title slot is a fundamentally
    /// different box from a strip of the screen. It is ~44pt tall rather than
    /// as tall as the bar likes, it is bounded by the side bar items rather
    /// than by the screen, its margins belong to the navigation bar, and — the
    /// part that costs a material — it already composites what it holds.
    public enum Style: Sendable {
        /// A free-floating strip under the navigation bar, on the screen's own
        /// margins. Carries its own glass and its own shadow.
        case floating
        /// `navigationItem.titleView`. Compact, marginless, and BARE: the
        /// navigation bar supplies the backdrop, so the bar contributes only
        /// its lens and its titles.
        case navigationTitle

        var capsuleHeight: CGFloat {
            switch self {
            case .floating: 42
            // 44pt: the standard UIKit bar-item touch height, stated outright
            // rather than measured from the bar's private view tree.
            //
            // ⚠️ Worth knowing, because it is visible: 44 is the size of the
            // item's TOUCH TARGET (the platter), not of the glass circle it
            // draws. The drawn circle measures 36 — the platter inset 4pt a side
            // — so a 44pt capsule stands 8pt taller than the buttons beside it
            // rather than flush with them. `-foryou-trace-chrome` prints `tabsH`
            // beside `itemH` if that comparison ever needs re-taking; 36 is the
            // value that makes the three read as one row.
            case .navigationTitle: 44
            }
        }

        var topMargin: CGFloat {
            switch self {
            case .floating: 4
            case .navigationTitle: 0
            }
        }

        var bottomMargin: CGFloat {
            switch self {
            case .floating: 8
            case .navigationTitle: 0
            }
        }

        /// Inset from the host's leading and trailing edges.
        var horizontalMargin: CGFloat {
            switch self {
            case .floating: Spacing.lg
            // The navigation bar decides where the title slot begins and ends;
            // a margin of ours inside it would be a second opinion.
            case .navigationTitle: 0
            }
        }

        /// Whether the bar draws its own material and shadow.
        var carriesBackdrop: Bool {
            switch self {
            case .floating: true
            // TRUE, after measuring the alternative. The first cut assumed the
            // navigation bar composites its title view the way it composites a
            // bar BUTTON item — through the system's own glass capsule, the
            // rule `GlassSegmentRow` documents — and therefore rendered bare to
            // avoid the double-bubble. It does not: bar items get a capsule,
            // the title slot gets nothing, and scrolled content showed straight
            // through the titles. See `-foryou-backdrop-off` for the A/B.
            case .navigationTitle: !ProcessInfo.processInfo.arguments.contains("-foryou-backdrop-off")
            }
        }

        /// Breathing room around a segment's title, which is what decides how
        /// wide the strip is overall.
        ///
        /// Tighter in a title slot, and by measurement rather than taste: the
        /// navigation bar hands the slot 258pt of the 290pt between the side
        /// items (it reserves ~16pt either side), and at the floating bar's
        /// padding three titles plus two badges need 269 — an 11pt shortfall
        /// that makes the strip scroll and clip a title mid-word. 8pt buys back
        /// 24pt, which is the difference between "fits" and "scrolls".
        var segmentPadding: CGFloat {
            switch self {
            case .floating: Spacing.lg
            case .navigationTitle: Spacing.sm
            }
        }

        /// How hard a segment insists on the width its title measures — and so,
        /// what gives when the host is narrower than the strip wants to be.
        ///
        /// A floating bar has the screen's width and a scroll view to fall back
        /// on, so its minimums are required and the strip overflows and scrolls.
        /// A title view has only what the side buttons leave it and nowhere to
        /// scroll to that would not hide a tab, so its minimums are breakable
        /// and the titles truncate where they stand. The badges never take part
        /// in either: they refuse to compress at all.
        var segmentWidthPriority: UILayoutPriority {
            switch self {
            case .floating: .required
            case .navigationTitle: .defaultHigh
            }
        }

        /// Whether the bar states a width, or takes whatever it is given.
        ///
        /// A floating bar spans the screen. A title view must HUG: the
        /// navigation bar hands the slot whatever is left between the side
        /// items, and a bar that claims all of it is a bar that can sit over
        /// them.
        var hugsContent: Bool {
            switch self {
            case .floating: false
            case .navigationTitle: true
            }
        }

        /// Total height including margins.
        var height: CGFloat { capsuleHeight + topMargin + bottomMargin }
    }

    private enum Metrics {
        /// Breathing room between the capsule's edge and the first segment.
        static let capsulePadding: CGFloat = 5
        /// Inset of the lens inside the capsule.
        static let lensInset: CGFloat = 4
        static let interSegmentSpacing: CGFloat = 2
    }

    /// Total height a `.floating` host reserves as safe area, margins included.
    ///
    /// `nonisolated` because owners read it to size the bar and to set
    /// `additionalSafeAreaInsets.top`, often from a nested constants type that
    /// carries no actor isolation of its own — a `UIView` subclass's statics
    /// are `@MainActor` by inference and would be unreachable from there. The
    /// same reason `InlineFilterTrayView.height` states it.
    public nonisolated static let height: CGFloat = Style.floating.height

    public let style: Style

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
    /// The segment strip. A subclass only so it can say when it has finished
    /// positioning its arranged subviews — see `SegmentRow`.
    private let row = SegmentRow()
    private var segments: [SegmentView] = []
    private var progress: CGFloat = 0
    private var scrubPan: UIPanGestureRecognizer!
    /// Where `progress` stood when the current capsule drag began.
    private var scrubOrigin: CGFloat = 0

    public init(titles: [String], style: Style = .floating) {
        self.titles = titles
        self.style = style
        super.init(frame: .zero)

        if style.carriesBackdrop {
            shadowHost.layer.shadowColor = UIColor.black.cgColor
            shadowHost.layer.shadowOpacity = 0.12
            shadowHost.layer.shadowRadius = 10
            shadowHost.layer.shadowOffset = CGSize(width: 0, height: 3)
        }
        // Full width, standard margins — a floating capsule is a bar, not a
        // badge, so it reads the same on every screen instead of growing and
        // shrinking with whatever the segment titles happen to measure. A title
        // view is the opposite case and hugs; see `Style.hugsContent`.
        shadowHost.constrain(in: self) { parent in
            shadowHost.topAnchor.constraint(equalTo: parent.topAnchor, constant: style.topMargin)
            shadowHost.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -style.bottomMargin)
            shadowHost.leadingAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: style.horizontalMargin
            )
            shadowHost.trailingAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -style.horizontalMargin
            )
        }

        capsule.clipsToBounds = true
        // Stated HERE, not left to the first layout pass. `layoutSubviews` also
        // maintains the radius (the capsule's height is not constant — Dynamic
        // Type moves it), but a shape that only exists after a layout pass is a
        // shape that does not exist for the frame in which the material first
        // renders, and the glass draws as a hard-cornered rectangle for it.
        capsule.layer.cornerCurve = .continuous
        capsule.layer.cornerRadius = effectiveCapsuleHeight / 2
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
        // ⚠️ THE authoritative moment to size the lens. Everything else that
        // calls `applyProgress` is a hint that may be one pass early; this is
        // the one call that cannot be, because it fires after the row has
        // placed the very frames the lens is derived from.
        row.onLayout = { [weak self] in self?.applyProgress() }
        buildSegments()
        row.constrain(in: content) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Metrics.capsulePadding)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.capsulePadding)
        }

        // How the content relates to the capsule's width — and this is what
        // decides whether "too much content" becomes SCROLLING or TRUNCATION.
        //
        // `.floating` uses `>=`: the row's own minimums push `content` wider
        // than the capsule when they have to, and the scroll view takes it from
        // there. That is right for a bar that spans the screen.
        //
        // `.navigationTitle` uses `==`, and it is load-bearing. A title view
        // cannot grow past what the side buttons leave it (measured: the bar
        // caps the slot at 258pt however much more the bar asks for), so a row
        // allowed to exceed that does not scroll gracefully — the trailing
        // badge is simply cropped by the capsule's edge, which is the one thing
        // the badge rules exist to prevent. Pinning the content TO the capsule
        // pushes the shortfall down into the segments, where the breakable
        // width minimums and the labels' low compression resistance turn it
        // into a truncated title and intact badges.
        //
        // Symptom this fixes, in numbers: after a pull-to-refresh the bar's
        // request grew 245 → 258 (the cap) with 25pt of content still
        // outstanding, and "Short 99" lost half its badge off the trailing edge
        // while "Activity" sat there untruncated with room to give.
        content.widthAnchor.constraint(
            equalTo: scroller.frameLayoutGuide.widthAnchor,
            multiplier: 1
        ).isActive = style.hugsContent
        content.widthAnchor.constraint(
            greaterThanOrEqualTo: scroller.frameLayoutGuide.widthAnchor
        ).isActive = !style.hugsContent


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

        // The segments re-pin their own widths on a text-size change; a hugging
        // bar's total width is the sum of those, so it has to re-state its
        // intrinsic size in the same breath or the navigation bar keeps sizing
        // the slot from the old measurement.
        if style.hugsContent {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentSizeCategoryChanged),
                name: UIContentSizeCategory.didChangeNotification,
                object: nil
            )
        }

        applyProgress()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A floating bar states only its height and spans whatever it is pinned
    /// to. A title view states BOTH, because the navigation bar sizes the slot
    /// from this and nothing else: a scroll view has no intrinsic size of its
    /// own, so without a width here the bar would measure zero and vanish, and
    /// with an unbounded one it would claim room the side items need.
    ///
    /// The width is the row's fitted width — the segments' pinned minimums plus
    /// their spacing — so the capsule is exactly as wide as its titles. It has
    /// to be re-derived whenever a badge appears or a text size changes, which
    /// is what the `invalidateIntrinsicContentSize` calls below are for.
    public override var intrinsicContentSize: CGSize {
        guard style.hugsContent else {
            return CGSize(width: UIView.noIntrinsicMetric, height: style.height)
        }
        // Derived from the segments' own pinned widths rather than measured off
        // the row: `systemLayoutSizeFitting` answers from the row's CURRENTLY
        // resolved constraints, which lag a badge by one layout pass, while a
        // segment knows its target width the instant it is set.
        //
        // ⚠️ The row is `fillEqually`, so the width is the WIDEST segment times
        // the count — not the sum of the individual minimums. Summing them
        // under-measures by (widest − each) and the capsule asks for less room
        // than its own contents need, which is a scrolling strip that clips a
        // title mid-word ("Activity" → "tivity") with space going spare beside
        // it. Measured both ways before believing it: summed 208pt vs 227pt
        // actual on three titles.
        let widest = segments.map(\.pinnedWidth).max() ?? 0
        let spacing = Metrics.interSegmentSpacing * CGFloat(max(0, segments.count - 1))
        return CGSize(
            width: ceil(widest * CGFloat(segments.count) + spacing) + Metrics.capsulePadding * 2,
            height: effectiveCapsuleHeight + style.topMargin + style.bottomMargin
        )
    }

    /// Materialized in-window, never in init: creating a real effect off
    /// screen stalls the render server on headless CI simulators (the same
    /// rule `ChatInputBar` and `SnapGlassCardView` follow).
    private func materializeEffects() {
        guard window != nil, style.carriesBackdrop else { return }
        if capsule.effect == nil {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-tabbar-shape-trace") {
                print(String(format: "[tabshape] materialize h=%.1f r=%.1f laidOut=%@",
                             capsule.bounds.height, capsule.layer.cornerRadius,
                             hasLaidOut ? "true" : "false"))
            }
            #endif
            // Shape before material. This runs from `didMoveToWindow`, which can
            // land before the first layout pass has given the capsule its real
            // bounds — and a `UIGlassEffect` switched on over a zero-radius
            // layer renders one frame of hard corners before the radius catches
            // up. Enforcing it synchronously here means the first frame the
            // material is ever drawn in is already a capsule.
            enforceCapsuleShape()
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

    /// Whether a layout pass has ever run — the fact that decides whether the
    /// capsule's bounds are real or still zero when the material goes live.
    ///
    /// `-tabbar-shape-trace` prints both moments, and they are the reason the
    /// radius has a fallback rather than being derived from `bounds` alone.
    /// Measured at launch: **the first layout pass runs at `h=0.0`, and the
    /// glass is switched on at `h=0.0` as well** — so a radius computed only
    /// from bounds would be `0/2` for the first frame the material is ever
    /// drawn in, which is precisely the square flash. A display-link probe
    /// cannot see this window: its first sample lands after both events.
    private var hasLaidOut = false

    public override func layoutSubviews() {
        super.layoutSubviews()
        #if DEBUG
        if !hasLaidOut, ProcessInfo.processInfo.arguments.contains("-tabbar-shape-trace") {
            print(String(format: "[tabshape] first layout h=%.1f r=%.1f glass=%@",
                         capsule.bounds.height, capsule.layer.cornerRadius,
                         capsule.effect != nil ? "on" : "off"))
        }
        #endif
        hasLaidOut = true
        enforceCapsuleShape()
        if style.carriesBackdrop {
            shadowHost.layer.shadowPath = UIBezierPath(
                roundedRect: shadowHost.bounds,
                cornerRadius: shadowHost.bounds.height / 2
            ).cgPath
        }
        resolveSegmentsThenApplyProgress()
    }

    /// Re-derives the lens, for the paths that change geometry outside a layout
    /// pass (a badge arriving, a transition restoring the bar).
    ///
    /// This is a HINT, not the guarantee. The guarantee is `row.onLayout` —
    /// see `SegmentRow`.
    private func resolveSegmentsThenApplyProgress() {
        content.layoutIfNeeded()
        applyProgress()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        materializeEffects()
    }

    /// Rounds the capsule to a true capsule, from whatever bounds it currently
    /// has — and from the style's stated height while it has none.
    ///
    /// Called from three places on purpose: `init` (so the shape exists before
    /// anything is drawn), `didMoveToWindow` (before the material is switched
    /// on), and every `layoutSubviews` (because the height is not a constant —
    /// Dynamic Type moves it, and a stale radius on a taller capsule reads as a
    /// lozenge). It is idempotent and costs two property writes.
    private func enforceCapsuleShape() {
        // The fallback matters: bounds are zero until the first layout pass, and
        // `0 / 2` is a square. Falling back to the style's own height means the
        // radius is never wrong, only occasionally early.
        let height = capsule.bounds.height > 0 ? capsule.bounds.height : effectiveCapsuleHeight
        capsule.layer.cornerCurve = .continuous
        capsule.layer.cornerRadius = height / 2
    }

    /// The segments have re-measured themselves; a hugging bar's own size is
    /// derived from theirs, so it re-states it.
    @objc private func contentSizeCategoryChanged() {
        invalidateIntrinsicContentSize()
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

    /// What a segment shows beside its title, and how.
    ///
    /// The two cases are different ANSWERS, not two skins on one: a count says
    /// "eleven conversations are waiting", a dot says "there is something here
    /// you have not seen". A surface should pick the one it can honour. The
    /// Messages inbox counts real, countable, individually-actionable rows and
    /// shows the number; For You is telling you a page has moved on since you
    /// looked, where the exact figure is noise the viewer cannot act on
    /// item-by-item.
    ///
    /// The value carries the style rather than the bar holding a mode, so a
    /// segment cannot be left rendering a stale presentation after its host
    /// changes its mind — every update states both facts at once.
    public enum BadgeStyle: Equatable, Sendable {
        /// A numeric pill. Zero shows nothing.
        case count(Int)
        /// Presence only — a small dot, no number.
        case dot(isVisible: Bool)

        /// Whether anything is drawn at all — the one question both cases
        /// answer the same way, and the one a host asks to decide whether a
        /// segment currently carries a signal.
        public var isVisible: Bool {
            switch self {
            case .count(let value): value > 0
            case .dot(let visible): visible
            }
        }
    }

    /// The count beside a segment's title; 0 hides it. Numeric by definition —
    /// the convenience for hosts that count things.
    public func setBadge(_ count: Int, at index: Int) {
        setBadge(.count(count), at: index)
    }

    /// The badge beside a segment's title, count or dot.
    public func setBadge(_ badge: BadgeStyle, at index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].setBadge(badge)
        // A badge changes the segment's pinned width, so the lens has to
        // re-derive its geometry from the new frames — and a HUGGING bar has to
        // re-state its whole size, because its width is the sum of those
        // segments.
        //
        // ⚠️ ORDER: lay the row out FIRST, then invalidate. `intrinsicContentSize`
        // measures the row, and the segment's width constraint was changed one
        // line ago — invalidating before the row has resolved it publishes the
        // PRE-badge measurement, and the host sizes the slot from that. Measured:
        // the capsule asked for 258pt of a 290pt slot while its content needed
        // 269, so it scrolled and cut "Activity" to "tivity" — with 32pt of room
        // going spare beside it.
        setNeedsLayout()
        layoutIfNeeded()
        invalidateIntrinsicContentSize()
        // The SEGMENTS have to be resolved before the lens is derived from
        // them, and `layoutIfNeeded()` above only guarantees this view's own
        // subviews — not the segments two levels down inside the scroll
        // content. Without this the lens keeps its pre-badge width and the
        // count renders outside its own selection pill.
        resolveSegmentsThenApplyProgress()
    }

    /// The frame the selection pill currently occupies, and the frame of the
    /// segment it is supposed to be framing — equal, at rest, to within a
    /// rounding error.
    ///
    /// Exposed so a host can assert the invariant instead of eyeballing a
    /// screenshot: the lag this catches is invisible until a badge changes a
    /// segment's width, and then it is the whole bug.
    public var debugLensAlignment: (lens: CGRect, segment: CGRect)? {
        let index = min(max(selectedIndex, 0), segments.count - 1)
        guard segments.indices.contains(index) else { return nil }
        return (lens.frame, lensFrame(for: index))
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
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        layoutIfNeeded()
        resolveSegmentsThenApplyProgress()
    }

    /// How many points of segment strip the capsule cannot show at its current
    /// width — zero when everything fits.
    ///
    /// A hosted bar has no other way to tell the difference between "the tabs
    /// fit" and "the tabs are scrolled and the last badge is off the edge",
    /// which look identical in a screenshot taken at the wrong moment.
    public var debugOverflow: CGFloat {
        max(0, scroller.contentSize.width - scroller.bounds.width)
    }

    /// The capsule's height in force. The style states it outright — there is
    /// no host-supplied override, by decision: an earlier build derived it from
    /// the navigation bar's own item views and was replaced with a stated
    /// constant, because a geometric read of a private view tree is a lot of
    /// machinery to keep correct for a number the system does not vary.
    private var effectiveCapsuleHeight: CGFloat { style.capsuleHeight }

    /// The capsule's rendered shape, for a host that wants to prove there is no
    /// square-cornered frame rather than squint at a screen recording.
    ///
    /// A capsule holds `radius == height / 2` at every instant. Anything less is
    /// a lozenge; zero is the square flash. Reported alongside whether the
    /// material is live, because a shape is only visible once there is something
    /// to shape.
    public var debugCapsuleShape: (radius: CGFloat, height: CGFloat, hasEffect: Bool) {
        (capsule.layer.cornerRadius, capsule.bounds.height, capsule.effect != nil)
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
            let segment = SegmentView(
                title: title,
                titlePadding: style.segmentPadding,
                widthPriority: style.segmentWidthPriority
            )
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

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-tabbar-shape-trace") {
            let frames = segments.map { String(format: "%.1f@%.1f", $0.frame.width, $0.frame.minX) }
            let pinned = segments.map { String(format: "%.1f", $0.pinnedWidth) }
            print(String(
                format: "[tabshape] p=%.2f self=%.1f row=%.1f@%.1f content=%.1f segs=[%@] pinned=[%@] lens=%.1f@%.1f",
                progress, bounds.width, row.bounds.width, row.frame.minX, content.bounds.width,
                frames.joined(separator: " "), pinned.joined(separator: " "), rect.width, rect.minX
            ))
        }
        #endif
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

// MARK: - Segment row

/// The segment strip, which exists as a subclass for ONE reason: to announce
/// that it has finished positioning its arranged subviews.
///
/// ⚠️ **The selection lens is built entirely out of segment FRAMES, and a stack
/// view positions its arranged subviews in its OWN `layoutSubviews` — which
/// runs after its superview's.** So every place the bar derives the lens
/// (`layoutSubviews`, `setBadge`, `setProgress`) is reading frames from the
/// previous pass. That is invisible while the segments never change size, and
/// it is the whole bug the moment a badge widens one: measured on a badge
/// arriving, the row had its new width (184) while its segments still carried
/// the frames they had at the old one (77 each, against a pinned 91) — so the
/// lens framed 77pt of a 91pt segment and the "99" it was supposed to enclose
/// rendered outside its own selection pill, permanently, because nothing ever
/// asked again.
///
/// `layoutIfNeeded()` on an ancestor does NOT fix it: when nothing is flagged
/// dirty at that instant the call is a no-op, and the stack still lays its
/// children out later in the same pass. The only reliable moment is this one.
private final class SegmentRow: UIStackView {
    /// Fired after every layout pass, once the arranged subviews have frames.
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        // Safe to drive the lens from here: it is a SIBLING of this row inside
        // the scroll content, so positioning it touches nothing this pass owns
        // and cannot re-enter.
        onLayout?()
    }
}

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
    /// Breathing room added around the measured title; see `Style.segmentPadding`.
    private let titlePadding: CGFloat
    /// How hard this segment insists on its measured width; see where the
    /// constraint is built for why the two hosts differ.
    private let widthPriority: UILayoutPriority
    private var pinnedWidthConstraint: NSLayoutConstraint!

    /// The width this segment has just asked for — readable the instant it is
    /// set, where the resolved frame is a layout pass behind. A hugging bar
    /// sums these to state its own size.
    var pinnedWidth: CGFloat { pinnedWidthConstraint.constant }

    init(title: String, titlePadding: CGFloat, widthPriority: UILayoutPriority) {
        self.title = title
        self.titlePadding = titlePadding
        self.widthPriority = widthPriority
        super.init(frame: .zero)

        for (label, weight) in [(plainLabel, UIFont.Weight.regular), (boldLabel, .semibold)] {
            label.text = title
            label.font = .preferredFont(forTextStyle: .subheadline, weight: weight, maximumPointSize: SegmentView.maximumTitlePointSize)
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.isUserInteractionEnabled = false
            // The TITLE is what gives when there is not enough room. A title
            // that loses its tail is still a title you can read and tap; a
            // badge that loses its tail is a wrong number ("12" cropped to "1"
            // is not a smaller count, it is a lie), and a badge cropped to a
            // sliver is furniture. So the label truncates and the badge, below,
            // refuses to compress at all.
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            // Bounds the content to its segment, which is what turns "too
            // narrow" into truncation. Centred content with no width bound does
            // not compress — it simply overflows its segment and draws over the
            // neighbouring one, so the compression-resistance priorities above
            // would never come into play at all.
            content.widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor)
        }
        plainLabel.constrain(in: self) { _ in
            plainLabel.centerXAnchor.constraint(equalTo: boldLabel.centerXAnchor)
            plainLabel.centerYAnchor.constraint(equalTo: boldLabel.centerYAnchor)
            // Truncation has to reach BOTH weights or it reaches neither: the
            // regular label is centred on the semibold one and otherwise keeps
            // its own intrinsic width, so under compression the semibold would
            // shorten to "Activi…" while the regular kept drawing "Activity"
            // through it at the crossfade's other end.
            //
            // ⚠️ `<=`, NEVER `==`. Equality pulls in both directions, and the
            // regular label is the NARROWER of the pair — its own hugging then
            // drags the semibold label down to the regular measurement and
            // truncates every title with room to spare. Measured: "Activity"
            // laid out at 51.0 needing 54.3, on a bar with 45pt of slack.
            plainLabel.widthAnchor.constraint(lessThanOrEqualTo: boldLabel.widthAnchor)
        }

        // The badge never yields. Required in BOTH directions: compression
        // resistance so it cannot be squeezed into a wrong number, and hugging
        // so a stack with room to spare hands the slack to the title instead of
        // inflating the pill.
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
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
        // allowed to get.
        //
        // Its PRIORITY is what decides what happens when the host is too narrow
        // for that minimum, and the two hosts want opposite answers. A floating
        // bar spans the screen and can scroll, so the minimum is required and
        // the strip overflows. A title view cannot scroll out from between two
        // bar buttons without hiding a tab, so its minimum is breakable and the
        // titles truncate in place instead.
        pinnedWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        pinnedWidthConstraint.priority = widthPriority
        pinnedWidthConstraint.isActive = true
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

    func setBadge(_ style: PagedTabBar.BadgeStyle) {
        badge.apply(style)
        badge.isHidden = !style.isVisible
        // The badge is a sibling in the stack, so its own hidden state is what
        // the accessibility label has to carry — VoiceOver reads the segment as
        // one element, and a badge nobody announces is a badge nobody gets. A
        // dot has no number to read out, so it is announced as what it means
        // rather than as what it looks like.
        accessibilityValue = switch style {
        case .count(let value): value > 0 ? "\(value) new" : nil
        case .dot(let visible): visible ? "unread" : nil
        }
        updatePinnedWidth()
    }

    @objc private func contentSizeCategoryChanged() {
        updatePinnedWidth()
    }

    /// Width = the semibold title plus the badge (when shown) plus breathing
    /// room, so the lens has somewhere to sit and the row never reflows.
    private func updatePinnedWidth() {
        let bold = UIFont.preferredFont(forTextStyle: .subheadline, weight: .semibold, maximumPointSize: Self.maximumTitlePointSize)
        var width = ceil((title as NSString).size(withAttributes: [.font: bold]).width) + titlePadding
        if !badge.isHidden {
            width += badge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + Spacing.xs
        }
        pinnedWidthConstraint.constant = width
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

        dotWidth = widthAnchor.constraint(equalToConstant: Self.dotDiameter)
        dotHeight = heightAnchor.constraint(equalToConstant: Self.dotDiameter)
    }

    /// A dot small enough to read as punctuation beside the title rather than
    /// as a second element competing with it — the point of choosing presence
    /// over a number is that it should barely interrupt the word.
    private static let dotDiameter: CGFloat = 8

    /// Sizing for dot mode. Inactive in count mode, where the label's own
    /// insets are what size the pill.
    private var dotWidth: NSLayoutConstraint!
    private var dotHeight: NSLayoutConstraint!

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func apply(_ style: PagedTabBar.BadgeStyle) {
        switch style {
        case .count(let count):
            // Past 99 the pill would out-measure its own segment title.
            label.text = count > 99 ? "99+" : String(count)
            label.isHidden = false
            dotWidth.isActive = false
            dotHeight.isActive = false
        case .dot:
            // ⚠️ The label is hidden AND the size is stated. A hidden view
            // still participates in Auto Layout outside a stack view, so its
            // pinned insets would keep sizing the badge to a number nobody can
            // see — a "dot" as wide as the count it replaced.
            label.isHidden = true
            dotWidth.isActive = true
            dotHeight.isActive = true
        }
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
