import UIKit

/// A floating Liquid Glass tab capsule that tracks a horizontal pager: a lens
/// slides between segments in step with the pages beneath it.
///
/// Built for the Messages inbox (All / Requests / Suggestions) and reused
/// unchanged by the For You grid (Discover / Following). It knows nothing about
/// either — it takes titles and reports an index, so a third host is a `titles`
/// array and two closures.
///
/// All three hosts wear it as `navigationItem.titleView` (`.navigationTitle`)
/// — Messages, For You, and the profile's relationship lists — which is why
/// that style carries the measured constants. `.floating` is the original
/// arrangement and still complete, but has no host today, so treat its numbers
/// as unverified against real content.
///
/// ⚠️ **A title view scrolls its overflow.** An earlier revision of this file
/// said it could not, and pinned the content width with `==` to force
/// truncation instead; that variant is gone. See the `content.widthAnchor`
/// constraint and `PagedTabBarTitleOverflowTests`.
///
/// **Anatomy.** A full-width capsule of `UIGlassEffect` inset by the standard
/// margin, with a tinted overlay marking the active segment. **No shadow and no
/// hairline** — the material is the whole of the edge, so content scrolls
/// *beneath* the capsule and is seen through the glass rather than being fenced
/// off from it. A drop shadow was carried here until it was removed for a flat
/// finish; nothing in the bar sets one now, and the wrapper view that existed
/// only to hold it (a shadow on the capsule's own layer would have been clipped
/// by its corner radius) went with it. Segments share the width
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
        /// margins. Carries its own glass.
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

        /// Whether the bar draws a material of its own.
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

        /// Clearance from the lens's LEADING edge to the title — and, at
        /// `trailingInset`, the same number at the other end, so a segment's
        /// contents sit dead centre in it.
        ///
        /// **7pt is what symmetry costs here, and it is free.** The two ends
        /// were 6 and 8 for a while, on the argument that a filled badge ends
        /// exactly where it is drawn where a letter carries its own side
        /// bearing. True as far as it goes, but it left the contents 1pt off
        /// centre, and a tab bar's segments are read as a row — an even margin
        /// on both sides is the stronger signal. Meeting in the middle is
        /// exactly cost-neutral: each segment gains a point at one end and
        /// gives one back at the other.
        ///
        /// ⚠️ 8pt on BOTH ends is not available. The navigation bar caps this
        /// title view at **258pt** (measured by asking for more — the bar
        /// requested 269 and was given 258), and 8/8 needs 263; buying it would
        /// mean squeezing `badgeSpacing` to 2pt or zeroing the gap between
        /// segments, which spends two constants to move one edge.
        var leadingInset: CGFloat {
            switch self {
            // Unchanged for a floating bar, which has the screen's width and
            // no reason to economise: 8 at both ends reproduces the
            // `Spacing.lg` padding it has always had.
            case .floating: Spacing.sm
            case .navigationTitle: 7
            }
        }

        /// Clearance from the last thing in the segment — the badge, when there
        /// is one — to the lens's TRAILING edge. Equal to the leading inset;
        /// see there for why they meet in the middle rather than at 8.
        var trailingInset: CGFloat { leadingInset }

        /// Breathing room around a segment's contents, which is what decides
        /// how wide the strip is overall.
        var segmentPadding: CGFloat { leadingInset + trailingInset }

        /// How far the contents sit from the segment's centre.
        ///
        /// Zero while the two insets match, which is the point — but derived
        /// rather than stated, so that unequal insets stay expressible: a
        /// segment is as wide as its contents plus both insets, so centred
        /// contents would hand each end the MEAN of the two, and only a shift
        /// of half their difference gives each the number it claims.
        var contentOffset: CGFloat { (leadingInset - trailingInset) / 2 }

        /// The gap between a title and its badge.
        ///
        /// Tighter than either inset, and that is the point: the count belongs
        /// to the word beside it, and the pair reads as one object with air
        /// around it rather than as three evenly spaced things. It is also
        /// where the trailing inset's extra points come from — the two badged
        /// segments give up 2pt each here to buy 2pt at every segment's
        /// trailing edge, which is what keeps the total at 257 of 258.
        var badgeSpacing: CGFloat { Spacing.xs }

        /// How hard a segment insists on the width its title measures — and so,
        /// what gives when the host is narrower than the strip wants to be.
        ///
        /// A floating bar has the screen's width and a scroll view to fall back
        /// on, so its minimums are required and the strip overflows and scrolls.
        /// A title view has only what the side buttons leave it and nowhere to
        /// scroll to that would not hide a tab, so its minimums are breakable
        /// and the titles truncate where they stand. The badges never take part
        /// in either: they refuse to compress at all.
        ///
        /// ⚠️ **Required on BOTH now, and this changed.** A title view used to
        /// break its minimums and truncate in place, on the reasoning that it
        /// could not scroll out from between two bar buttons without hiding a
        /// tab. That reasoning traded one invisible tab for one unreadable
        /// title — and truncation takes the SELECTED title first, which is the
        /// one the viewer most needs. A strip that scrolls hides a tab
        /// reachably, and `keepLensVisible` brings the selected one back
        /// whenever the selection moves, so nothing the viewer is actually
        /// looking at is ever the thing that got hidden.
        var segmentWidthPriority: UILayoutPriority { .required }

        /// The segment titles' type ramp, which differs because the two hosts
        /// give the bar wildly different amounts of room.
        ///
        /// A FLOATING bar owns the screen's width and can afford `.subheadline`.
        /// A TITLE VIEW gets only what the side bar items leave it, and at 15pt
        /// this bar's own content simply does not fit there: measured on the
        /// Messages inbox, three titles plus two badges needed 261pt of a slot
        /// that tops out at ~252 with NOTHING beside it and hands over 229 when
        /// the page publishes a trailing item. Every title truncated, and the
        /// SELECTED one truncated first.
        ///
        /// `.footnote` is 13pt, which is not a nudge downward to make the sums
        /// work — it is what UIKit itself sets on a `UISegmentedControl`, the
        /// stock control for this exact placement. It buys ~23pt across three
        /// titles, which is the difference between padded titles and clipped
        /// ones.
        var titleTextStyle: UIFont.TextStyle {
            switch self {
            case .floating: .subheadline
            case .navigationTitle: .footnote
            }
        }

        /// Where Dynamic Type stops growing the titles.
        ///
        /// A FLOATING bar has room to give and grows to 19pt before it stops.
        ///
        /// A TITLE VIEW does not grow AT ALL — 13 is `.footnote`'s own base
        /// size, so the cap is reached before the first step. That matches the
        /// bar it lives in: a navigation bar's title and its button items are
        /// both fixed-size chrome, so a capsule that grew between them would be
        /// the only thing on the row that moved, and it would move into space
        /// that does not exist. Measured at `accessibility-medium` with a 17pt
        /// cap: the slot is unchanged, every segment overruns it, and the
        /// shortfall lands on one — "All 11" lost its title completely and
        /// rendered as a bare badge in a lens.
        ///
        /// ⚠️ This is a real trade: viewers on large text sizes get tab titles
        /// at 13pt. It is the same bargain UIKit strikes for every navigation
        /// bar, and the CONTENT beneath still scales — but it is a bargain, not
        /// a free win.
        var maximumTitlePointSize: CGFloat {
            switch self {
            case .floating: 19
            case .navigationTitle: 13
            }
        }

        /// Where Dynamic Type stops growing a segment's badge. Capped for the
        /// same reason as the titles, and it has to be capped in the SAME style
        /// or the saving is spent: a badge refuses to compress, so every point
        /// it grows comes straight off the title beside it.
        var maximumBadgePointSize: CGFloat {
            switch self {
            case .floating: 15
            case .navigationTitle: 11
            }
        }

        /// The height of the lens — the selection pill — which is the capsule
        /// minus its inset on each side. Every other vertical measurement in a
        /// segment is expressed against THIS rather than against the capsule,
        /// because the lens is what a viewer actually sees a badge sitting
        /// inside.
        var lensHeight: CGFloat { capsuleHeight - Metrics.lensInset * 2 }

        /// The count pill's height: half the lens, which keeps it a small mark
        /// beside the title rather than a second element competing with it.
        ///
        /// **Compactness wins over four-sided symmetry, deliberately.** Equal
        /// margins on every side would mean `badgeHeight = lensHeight - 2 ×
        /// clearance`, and at any clearance the slot can afford that puts the
        /// pill at 28 of the lens's 36pt — a coin next to 13pt text, which is
        /// louder than the count deserves. So the pill stays at 18 and its
        /// vertical clearance (9pt) is simply larger than the horizontal
        /// insets (6pt leading, 8pt trailing). The HORIZONTAL spacing is what
        /// is balanced — see `leadingInset` and `trailingInset`.
        ///
        /// STATED, not measured from the label's text box. A pill sized by its
        /// text is as tall as the font's ascender plus descender, an asymmetric
        /// box whose centre is not where the digits look centred, and at 3× it
        /// lands on a half-pixel: measured 16.67pt tall with 10.3pt of lens
        /// above it and 9.3pt below. An even, stated number puts the two gaps
        /// on whole pixels and makes them equal by construction.
        var badgeHeight: CGFloat { (lensHeight / 2).rounded() }

        /// How the row divides itself between its segments — and it follows
        /// directly from whether the bar spans the screen or hugs its titles.
        ///
        /// A FLOATING bar has the screen's width whatever its titles measure,
        /// so equal slots are what make it read as one balanced control and
        /// give a short title the same target as a long one.
        ///
        /// A TITLE VIEW is only as wide as its contents, and equal slots there
        /// are actively expensive: `fillEqually` sizes every segment to the
        /// WIDEST, so one long title inflates all of them. Measured on the
        /// Messages inbox — All 41pt, Requests 89pt, Suggestions 98pt — equal
        /// slots asked for 3 × 98 = 308pt of a 240pt slot and clipped two
        /// titles, while "All" sat in a 75pt box it needed 41 of. Natural
        /// widths need 242 of the same 240, which the segments' own padding
        /// absorbs without a single character lost.
        var segmentDistribution: UIStackView.Distribution {
            switch self {
            case .floating: .fillEqually
            case .navigationTitle: .fill
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

        /// Total height including margins. Public because a host that places
        /// this bar by hand has to reserve the room it will take, and reserving
        /// a number of its own is how the two drift apart.
        public var height: CGFloat { capsuleHeight + topMargin + bottomMargin }
    }

    private enum Metrics {
        /// The lens's clearance inside the capsule, on EVERY side.
        ///
        /// One number, not two. It was 5 horizontally and 4 vertically, which
        /// meant the selection pill sat closer to the capsule's top and bottom
        /// than to its ends — invisible on a wide segment and obvious on a
        /// round one, where the eye reads the pill against the capsule's own
        /// curve. The horizontal figure is what gave way, because the vertical
        /// one is what decides the lens's HEIGHT, and that height is the
        /// diameter every disk in the bar is measured against.
        static let lensInset: CGFloat = 4
        /// Breathing room between the capsule's edge and the first segment —
        /// the same inset, seen from the horizontal axis.
        static var capsulePadding: CGFloat { lensInset }
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

    /// Whether the bar spreads across the width it is given instead of hugging
    /// its own titles.
    ///
    /// A `.navigationTitle` bar hugs, because a navigation bar hands it the slot
    /// left over between the side items and a bar that claimed all of it would
    /// sit over them. The SAME bar hosted inline on a screen has the screen's
    /// width, and hugging there leaves a short capsule stranded in the middle of
    /// a wide column. Turning this on gives it the `.floating` bar's own
    /// arrangement — equal slots, pinned to both ends — without giving it the
    /// floating bar's type ramp or its material, which still belong to where it
    /// docks.
    ///
    /// ⚠️ Three things move together, and leaving any one behind is visible.
    /// The DISTRIBUTION becomes `fillEqually`, or the slack lands on whichever
    /// segment the stack happens to favour. The ROW stops centring and pins to
    /// both ends, or the slack lands as margin either side and the segments
    /// never see it. And the bar stops STATING a width, or its intrinsic size
    /// argues with the host's constraint over a number the host owns.
    public var fillsWidth: Bool = false {
        didSet {
            guard fillsWidth != oldValue, style.hugsContent else { return }
            row.distribution = activeDistribution
            NSLayoutConstraint.deactivate(fillsWidth ? rowHugsConstraints : rowFillsConstraints)
            NSLayoutConstraint.activate(fillsWidth ? rowFillsConstraints : rowHugsConstraints)
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }


    /// Whether the bar is currently taking its width from its host rather than
    /// stating one — true for a floating bar always, and for a hugging bar that
    /// has been told to fill.
    private var spansItsHost: Bool { !style.hugsContent || fillsWidth }

    /// How the row divides itself RIGHT NOW, which is the style's answer only
    /// while the bar is hugging.
    private var activeDistribution: UIStackView.Distribution {
        spansItsHost ? .fillEqually : style.segmentDistribution
    }

    private var rowHugsConstraints: [NSLayoutConstraint] = []
    private var rowFillsConstraints: [NSLayoutConstraint] = []

    /// The segment the bar is reporting — updated by taps AND by the pages
    /// moving under it, so it is never stale. Reading it is how a
    /// `.valueChanged` handler learns WHICH segment — the same shape
    /// `UISegmentedControl` has, so the owner registers a `UIAction` rather
    /// than being handed a closure to store.
    public private(set) var selectedIndex: Int = 0
    /// A tap on the segment that is ALREADY selected.
    ///
    /// ⚠️ Its own channel, deliberately, rather than a `.valueChanged` that
    /// fires on a value that did not change. Re-selection is a different request
    /// from selection — "take me back to the top of what I am already looking
    /// at" rather than "show me this instead" — and answering it through the
    /// change event would make every handler on every screen wearing this bar
    /// defensive about being told nothing happened. Screens that have no answer
    /// for it simply leave this nil.
    public var onReselect: ((Int) -> Void)?

    private var titles: [String]
    private let capsule = UIVisualEffectView(effect: nil)
    /// Scrolls the segments when they out-measure the capsule. Below that
    /// width it never scrolls and is invisible in every sense.
    private let scroller = StripScrollView()
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
    /// The progress the strip was last scrolled to follow. A layout pass that
    /// changes nothing must not undo a scroll the viewer made by hand — see
    /// `keepLensVisible`.
    private var lensFollowedProgress: CGFloat?

    public init(titles: [String], style: Style = .floating) {
        self.titles = titles
        self.style = style
        super.init(frame: .zero)

        capsule.clipsToBounds = true
        // Stated HERE, not left to the first layout pass. `layoutSubviews` also
        // maintains the radius (the capsule's height is not constant — Dynamic
        // Type moves it), but a shape that only exists after a layout pass is a
        // shape that does not exist for the frame in which the material first
        // renders, and the glass draws as a hard-cornered rectangle for it.
        capsule.layer.cornerCurve = .continuous
        capsule.layer.cornerRadius = effectiveCapsuleHeight / 2
        // Full width, standard margins — a floating capsule is a bar, not a
        // badge, so it reads the same on every screen instead of growing and
        // shrinking with whatever the segment titles happen to measure. A title
        // view is the opposite case and hugs; see `Style.hugsContent`.
        //
        // The capsule is constrained DIRECTLY, with no wrapper. There used to be
        // one, for a single reason: the capsule clips to its corner radius, and
        // a shadow set on the same layer would have been clipped away with it.
        // With no shadow to host, the wrapper was a view that existed to hold a
        // property nothing sets.
        capsule.constrain(in: self) { parent in
            capsule.topAnchor.constraint(equalTo: parent.topAnchor, constant: style.topMargin)
            capsule.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -style.bottomMargin)
            capsule.leadingAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: style.horizontalMargin
            )
            capsule.trailingAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -style.horizontalMargin
            )
        }

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
        // Equal slots on a bar that spans the screen; natural widths on one that
        // hugs its titles — see `Style.segmentDistribution`. Segment widths are
        // minimums (`>=`) rather than exact in both cases, which is what lets a
        // floating row distribute its slack, and what still lets it out-measure
        // the capsule and scroll when the titles genuinely need more room than
        // the screen has.
        row.distribution = activeDistribution
        // ⚠️ THE authoritative moment to size the lens. Everything else that
        // calls `applyProgress` is a hint that may be one pass early; this is
        // the one call that cannot be, because it fires after the row has
        // placed the very frames the lens is derived from.
        row.onLayout = { [weak self] in self?.applyProgress() }
        buildSegments()
        row.constrain(in: content) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        // How the row sits between the capsule's ends.
        //
        // A floating bar PINS to both margins: it spans the screen, and equal
        // slots across that width are the look.
        //
        // A title view CENTRES between them, and that is load-bearing. A
        // navigation bar hands its title slot a width; it does not promise that
        // width is the one the view asked for. Measured: the capsule's intrinsic
        // width fell from 239 to 224 when a badge cleared, the bar kept handing
        // it 239, and `.fill` gave the whole 15pt of slack to ONE segment —
        // "All" rendered 52pt wide where its content needed 36, so a selection
        // that should have been a disk was an oval, and which segment got fat
        // was up to the stack. Centred, the slack lands where slack belongs: as
        // equal margin at both ends. Segments keep exactly the widths they asked
        // for, so the disk floor in `updatePinnedWidth` reaches the screen.
        //
        // Both sets are BUILT, and which one is live is `fillsWidth`'s to
        // decide — a hugging bar that is asked to fill has to stop centring, or
        // the extra width lands as margin at its two ends and the segments never
        // see it. See `fillsWidth`.
        rowHugsConstraints = [
            row.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor, constant: Metrics.capsulePadding
            ),
            row.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -Metrics.capsulePadding
            ),
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        ]
        rowFillsConstraints = [
            row.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Metrics.capsulePadding
            ),
            row.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Metrics.capsulePadding
            )
        ]
        NSLayoutConstraint.activate(spansItsHost ? rowFillsConstraints : rowHugsConstraints)

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
        //
        // ⚠️ **`>=` IS WHAT SHIPS, for both styles** — the `==` variant and the
        // `scrollsWhenCrowded` picker that chose between them are gone, so the
        // paragraphs above describe history, not behaviour. A crowded title
        // view SCROLLS today; it does not truncate. When the titles DO fit the
        // two are indistinguishable — Auto Layout satisfies `>=` at the
        // smallest width that works, which is the frame's.
        //
        // The profile's relationship lists depend on this: three counted titles
        // ("12.4K Followers") in the title slot must stay whole, and truncation
        // would collapse two of them into indistinguishable stubs. Pinned by
        // `PagedTabBarTitleOverflowTests` — flipping this back to `==` fails
        // there rather than in a screenshot nobody takes.
        content.widthAnchor.constraint(
            greaterThanOrEqualTo: scroller.frameLayoutGuide.widthAnchor
        ).isActive = true


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
    ///
    /// A bar that has been told to `fillsWidth` states no width for the same
    /// reason a floating one does not: the host owns that number now.
    public override var intrinsicContentSize: CGSize {
        guard !spansItsHost else {
            return CGSize(width: UIView.noIntrinsicMetric, height: style.height)
        }
        return CGSize(
            width: fittedWidth(for: activeDistribution),
            height: effectiveCapsuleHeight + style.topMargin + style.bottomMargin
        )
    }

    /// The width the segments add up to under a given arrangement.
    ///
    /// Derived from the segments' own pinned widths rather than measured off
    /// the row: `systemLayoutSizeFitting` answers from the row's CURRENTLY
    /// resolved constraints, which lag a badge by one layout pass, while a
    /// segment knows its target width the instant it is set.
    ///
    /// ⚠️ The measurement follows the DISTRIBUTION, and getting it wrong in
    /// either direction is visible. Under `fillEqually` every segment is sized
    /// to the WIDEST, so the width is widest × count — summing the individual
    /// minimums there under-measures by (widest − each) and the capsule asks
    /// for less room than its own contents need, which is a scrolling strip
    /// that clips a title mid-word ("Activity" → "tivity") with space going
    /// spare beside it (measured: summed 208pt vs 227pt actual on three
    /// titles). Under `.fill` each segment keeps its own width, so the sum IS
    /// the answer and widest × count would claim room the side items need.
    private func fittedWidth(for distribution: UIStackView.Distribution) -> CGFloat {
        let widths = segments.map(\.pinnedWidth)
        let total = switch distribution {
        case .fillEqually: (widths.max() ?? 0) * CGFloat(segments.count)
        default: widths.reduce(0, +)
        }
        let spacing = Metrics.interSegmentSpacing * CGFloat(max(0, segments.count - 1))
        return ceil(total + spacing) + Metrics.capsulePadding * 2
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
        // ⚠️ CLIPPING IS PART OF THE SHAPE, and re-asserted here rather than set
        // once in `init`. A corner radius alone does not round a
        // `UIVisualEffectView`: the material is drawn by the layer's contents,
        // and without `masksToBounds` the radius is a number nothing honours —
        // the capsule renders as a hard-edged blurry rectangle with its corner
        // radius still correctly set, which is why this looks like a shape bug
        // and reads in the debugger as a shape that is fine.
        //
        // Re-asserted rather than set once because it is cheap and the failure
        // is silent: anything that clears it leaves a bar that looks broken and
        // debugs as correct.
        capsule.clipsToBounds = true
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
    /// Replaces the segment titles, keeping the current selection.
    ///
    /// Segments are rebuilt rather than relabelled: a `SegmentView` pins its
    /// width to its SEMIBOLD title at construction — the reflow trap this file
    /// documents — so a title it did not measure would leave the lens sized for
    /// the old word.
    ///
    /// ⚠️ **Badges do not survive**, since they belong to the segments being
    /// replaced. A host that uses both has to re-apply them after this call.
    /// Nothing does today: the two badge hosts have fixed titles, and the host
    /// with changing titles (the profile's relationship lists) has no badges.
    /// What the segments currently read, in order.
    public var currentTitles: [String] { titles }

    public func setTitles(_ newTitles: [String]) {
        guard newTitles != titles else { return }
        titles = newTitles
        for segment in segments {
            row.removeArrangedSubview(segment)
            segment.removeFromSuperview()
        }
        buildSegments()
        // The selection is an index into a list that just changed length.
        selectedIndex = min(max(0, selectedIndex), max(0, titles.count - 1))
        // The strip's width follows its content, and the lens follows the
        // strip; both are settled by the layout pass `row.onLayout` completes.
        setNeedsLayout()
        // ⚠️ Load-bearing for a title view. `.navigationTitle` STATES an
        // intrinsic width — the navigation bar sizes the slot from it and
        // nothing else — so a retitle that doesn't invalidate leaves the bar
        // measured for the old words. "Friends" becoming "2 Friends" would be
        // laid out into a slot sized before the count existed.
        invalidateIntrinsicContentSize()
    }

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
        for view in [capsule, capsule.contentView, scroller, content, row] {
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

    /// The size a segment's badge is actually drawing at — the pill whose
    /// margins inside the lens are supposed to be equal on every side.
    public func debugBadgeSize(at index: Int) -> CGSize? {
        guard segments.indices.contains(index) else { return nil }
        return segments[index].badgeSize
    }

    /// How many points of segment strip the capsule cannot show at its current
    /// width — zero when everything fits.
    ///
    /// A hosted bar has no other way to tell the difference between "the tabs
    /// fit" and "the tabs are scrolled and the last badge is off the edge",
    /// which look identical in a screenshot taken at the wrong moment.
    /// Where the crowded strip is scrolled to, and a way to put it somewhere —
    /// standing in for the drag a test cannot perform.
    public var debugStripOffset: CGFloat { scroller.contentOffset.x }

    public func debugSetStripOffset(_ x: CGFloat) { scroller.contentOffset.x = x }

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
    /// Reports `clips` alongside the radius because the two fail SEPARATELY:
    /// clipping switched off leaves the radius reading perfectly correct while
    /// the capsule draws as a rectangle, which is indistinguishable from a
    /// working bar in every number except this one.
    public var debugCapsuleShape: (radius: CGFloat, height: CGFloat, hasEffect: Bool, clips: Bool) {
        (capsule.layer.cornerRadius, capsule.bounds.height, capsule.effect != nil, capsule.clipsToBounds)
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
    /// Fires a segment exactly as a finger on it would, `.valueChanged` and
    /// all — where `select(_:)` moves the lens without announcing anything.
    ///
    /// Exists because the tap path is otherwise unverifiable: the bar sits in
    /// the top band of the screen, which the simulator does not deliver
    /// injected touches to, so a host's tap-to-page wiring can only be
    /// exercised from a test.
    public func debugSimulateTap(at index: Int) {
        guard segments.indices.contains(index) else { return }
        selectSegment(index, fromTap: true)
    }

    public func select(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        selectSegment(index, fromTap: false)
    }

    /// A segment was chosen. Publishes through `.valueChanged` rather than a
    /// stored closure, so the owner wires this the way it would wire any
    /// system control.
    /// ⚠️ `fromTap` is what keeps re-selection honest. Setting a value to what
    /// it already is is a NO-OP; tapping the thing that is already chosen is an
    /// EVENT, and only the second one is a request. The profile mirrors every
    /// choice onto a second bar, so a `select` to the current segment happens on
    /// ordinary tab changes — announcing those as re-selections would scroll the
    /// list to the top every time the viewer merely changed tabs.
    private func selectSegment(_ index: Int, fromTap: Bool) {
        guard index != selectedIndex else {
            if fromTap { onReselect?(index) }
            return
        }
        selectedIndex = index
        sendActions(for: .valueChanged)
    }

    // MARK: - Moving between tabs
    //
    // ⚠️ **There is no gesture on this bar, and that is the design.** The
    // capsule used to be draggable — a grab that slid the lens and ran the
    // pages under the finger. It read well on a bar with room to spare and
    // fought everything else the moment there was not: a strip that overflows
    // has to yield the same drag to its own scroll view, so the same gesture on
    // the same control did one thing on three tabs and another on five, and a
    // vertical component in it belonged to the page underneath. Three
    // recognizers arbitrating one finger produced behaviour no rule could
    // state simply.
    //
    // Tapping a segment and swiping the pages are the two ways to change tabs
    // now. Both are unambiguous, both are what every other tab bar on the
    // platform does, and neither has anything to arbitrate with the horizontal
    // scrolling this strip does when it is crowded.

    private func buildSegments() {
        segments = titles.enumerated().map { index, title in
            let segment = SegmentView(
                title: title,
                titlePadding: style.segmentPadding,
                widthPriority: style.segmentWidthPriority,
                textStyle: style.titleTextStyle,
                maximumPointSize: style.maximumTitlePointSize,
                maximumBadgePointSize: style.maximumBadgePointSize,
                badgeHeight: style.badgeHeight,
                badgeSpacing: style.badgeSpacing,
                contentOffset: style.contentOffset,
                lensHeight: style.lensHeight
            )
            segment.addAction(
                UIAction { [weak self] _ in self?.selectSegment(index, fromTap: true) },
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
    /// ⚠️ **Only when the SELECTION moved.** This runs from `applyProgress`,
    /// which every layout pass calls — so following the lens unconditionally
    /// meant a viewer could drag the strip to see a hidden tab and have it
    /// snap back to the selection on the next pass, before they could reach
    /// what they had scrolled to. Chasing the lens is the answer to "the
    /// selection changed", not to "something laid out".
    ///
    /// Skipped mid-drag as well, so a scroll in progress is never yanked from
    /// under the finger by a page change arriving at the same time.
    private func keepLensVisible() {
        guard lensFollowedProgress != progress else { return }
        guard scroller.contentSize.width > scroller.bounds.width,
              !scroller.isDragging, !scroller.isDecelerating
        else { return }
        lensFollowedProgress = progress
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


// MARK: - Segment row

/// The segment strip, which exists as a subclass for ONE reason: to announce
/// that it has finished positioning its arranged subviews.
///
/// A scroll view that will take a drag which began on a button.
///
/// ⚠️ **`UIScrollView` refuses to cancel touches that started in a `UIControl`,
/// and that default is why the strip could not be scrolled by hand.** It is the
/// right default for a form — a finger resting on a switch should work the
/// switch, not the page. It is the wrong one for a strip of tabs, where every
/// segment IS a control and therefore EVERY drag starts on one: the scroll view
/// was there, it had somewhere to scroll, and it was never offered the gesture.
///
/// Cancelling is what turns a press-then-drag into a scroll. A press that does
/// not move is untouched by this and still arrives as a tap, which is what
/// keeps "tap to choose" working alongside "drag to see the rest".
private final class StripScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

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
    private let plainLabel = UILabel()
    private let boldLabel = UILabel()
    private let badge: BadgeView
    private let content = UIStackView()
    private let title: String
    /// Breathing room added around the measured title; see `Style.segmentPadding`.
    private let titlePadding: CGFloat
    /// How hard this segment insists on its measured width; see where the
    /// constraint is built for why the two hosts differ.
    private let widthPriority: UILayoutPriority
    /// The titles' type ramp, handed down by the host's style — see
    /// `Style.titleTextStyle` for why a title slot runs smaller than a
    /// floating bar.
    private let textStyle: UIFont.TextStyle
    /// Where Dynamic Type stops growing the titles; also from the style.
    private let maximumPointSize: CGFloat
    private var pinnedWidthConstraint: NSLayoutConstraint!

    /// The width this segment has just asked for — readable the instant it is
    /// set, where the resolved frame is a layout pass behind. A hugging bar
    /// sums these to state its own size.
    var pinnedWidth: CGFloat { pinnedWidthConstraint.constant }

    /// The pill's laid-out size, for a host asserting its margins.
    var badgeSize: CGSize { badge.bounds.size }

    /// The lens's height inside this segment, which is also the smallest width
    /// the segment may take — see `updatePinnedWidth`.
    private let lensHeight: CGFloat

    /// The gap between the title and its badge, handed down by the style.
    private let badgeSpacing: CGFloat

    /// How far the contents sit from the segment's centre, so that unequal
    /// leading and trailing insets both come out at their stated values.
    private let contentOffset: CGFloat

    init(
        title: String,
        titlePadding: CGFloat,
        widthPriority: UILayoutPriority,
        textStyle: UIFont.TextStyle,
        maximumPointSize: CGFloat,
        maximumBadgePointSize: CGFloat,
        badgeHeight: CGFloat,
        badgeSpacing: CGFloat,
        contentOffset: CGFloat,
        lensHeight: CGFloat
    ) {
        self.title = title
        self.titlePadding = titlePadding
        self.widthPriority = widthPriority
        self.textStyle = textStyle
        self.maximumPointSize = maximumPointSize
        self.badgeSpacing = badgeSpacing
        self.contentOffset = contentOffset
        self.lensHeight = lensHeight
        badge = BadgeView(maximumPointSize: maximumBadgePointSize, height: badgeHeight)
        super.init(frame: .zero)

        for (label, weight) in [(plainLabel, UIFont.Weight.regular), (boldLabel, .semibold)] {
            label.text = title
            label.font = .preferredFont(forTextStyle: textStyle, weight: weight, maximumPointSize: maximumPointSize)
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
        content.spacing = badgeSpacing
        content.isUserInteractionEnabled = false
        content.constrain(in: self) { parent in
            // Offset, not centred: the two horizontal insets differ, and this
            // half-difference is what makes each of them come out at its stated
            // value. See `Style.contentOffset`.
            content.centerXAnchor.constraint(equalTo: parent.centerXAnchor, constant: contentOffset)
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
    ///
    /// ⚠️ The badge is measured from its own text metrics, NOT through
    /// `systemLayoutSizeFitting`. That call resolves the badge's constraints at
    /// `.fittingSizeLevel` and came back ~10pt short of the pill it actually
    /// draws — invisible while `fillEqually` sized every segment to the widest
    /// one, and the whole bug under `.fill`, where the segment gets exactly the
    /// width stated here: "All 11" was pinned to 41pt, needed 51, and the title
    /// compressed to a bare "…" beside an intact badge.
    private func updatePinnedWidth() {
        let bold = UIFont.preferredFont(forTextStyle: textStyle, weight: .semibold, maximumPointSize: maximumPointSize)
        var width = ceil((title as NSString).size(withAttributes: [.font: bold]).width) + titlePadding
        if !badge.isHidden {
            width += badge.measuredWidth + badgeSpacing
        }
        // ⚠️ FLOOR at the lens's own height, which is what makes a short title's
        // selection a DISK rather than a squashed oval. The lens is as tall as
        // the segment minus its inset and as wide as the segment, so a segment
        // narrower than that height cannot draw a round pill at any radius —
        // its own corner rounding (height / 2) exceeds half its width and the
        // shape degenerates. Below the floor the title simply sits in more air.
        pinnedWidthConstraint.constant = max(lensHeight, width)
    }
}

// MARK: - Badge

/// The pending count beside a segment title: a filled capsule in notification
/// red, the same colour the bottom tab bar badges the app with.
///
/// It does NOT follow its segment's selection — see `applyFill` for why the
/// count stopped being chrome that dims with its title, and for why it matches
/// the bar below rather than the rows it summarises.
///
/// **Its height is given to it, not derived from its text.** The host states one
/// number (`Style.badgeHeight`) and the pill is exactly that tall in both
/// styles, so the clearance above and below it inside the selection lens is
/// equal by construction and stays equal when the font changes. The text only
/// ever decides how WIDE it is.
private final class BadgeView: UIView {
    private let label = UILabel()

    /// The pill's stated height; also its minimum width, so a single digit
    /// draws a circle rather than a squat lozenge.
    private let height: CGFloat

    init(maximumPointSize: CGFloat, height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
        label.font = .preferredFont(forTextStyle: .caption2, weight: .semibold, maximumPointSize: maximumPointSize)
        label.adjustsFontForContentSizeCategory = true
        // ⚠️ **White in both appearances, and stated outright.**
        //
        // This was a dynamic colour — the inverse of `.label`, dark-on-light and
        // light-on-dark — which is the right rule for a fill that FLIPS with the
        // appearance, as `.label` does. The fill is notification red now, and it
        // does not flip: it is red in both, so an inverting text colour put
        // near-black on saturated red every dark-mode night and called it
        // contrast. White is also what the system's own badges use, which is the
        // pairing this is matching.
        //
        // Static rather than semantic on purpose. `.systemBackground` does not
        // survive inside a `UIGlassEffect` content view — it resolved to white
        // in dark mode on a badge whose fill had also resolved to white, erasing
        // the count — and the lesson generalises: a colour the effect can
        // reinterpret is a colour that can disappear.
        label.textColor = .white
        label.textAlignment = .center
        // CENTRED, not pinned by insets. The pill's height is stated below and
        // its width is stated by `countWidth`, so the label's job is only to sit
        // in the middle of both — where pinning it by insets would make the text
        // box the thing that sizes the pill, which is exactly the asymmetry this
        // arrangement removes.
        label.constrain(in: self) { parent in
            label.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            label.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        backgroundColor = .secondaryLabel
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false

        // One pair of constraints, re-pointed per style: a count states the
        // stated height and a text-derived width, a dot states its diameter on
        // both axes. Keeping it to one pair means the two can never both be
        // live and fight.
        pillWidth = widthAnchor.constraint(equalToConstant: Self.dotDiameter)
        pillHeight = heightAnchor.constraint(equalToConstant: Self.dotDiameter)
        pillWidth.isActive = true
        pillHeight.isActive = true
    }

    /// A dot small enough to read as punctuation beside the title rather than
    /// as a second element competing with it — the point of choosing presence
    /// over a number is that it should barely interrupt the word.
    private static let dotDiameter: CGFloat = 8

    /// Clearance between the count and the pill's end caps, per side. Only ever
    /// widens the pill — a one-digit count is already round at the stated
    /// height, so this decides how a two- or three-digit one grows.
    private static let labelInset: CGFloat = 5

    /// The width this badge draws at, derived from its own text the instant the
    /// text is set — where `systemLayoutSizeFitting` answers from constraints
    /// that have not been resolved yet and under-reports by the label's whole
    /// width. The segment that hosts it pins itself from this, so it has to be
    /// right on the same turn of the run loop, not after a layout pass.
    ///
    /// Never narrower than the pill is tall: at that floor it is a circle, which
    /// is what a single digit should look like beside a title.
    var measuredWidth: CGFloat {
        switch style {
        case .count:
            let text = label.text ?? ""
            let width = (text as NSString).size(withAttributes: [.font: label.font as Any]).width
            return max(height, ceil(width) + Self.labelInset * 2)
        case .dot:
            return Self.dotDiameter
        }
    }

    /// The pill's own size, re-pointed between the stated count geometry and
    /// the dot's diameter by `apply`.
    private var pillWidth: NSLayoutConstraint!
    private var pillHeight: NSLayoutConstraint!

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    /// The style currently rendered, because the FILL depends on it and the
    /// fill is also re-derived on every selection change.
    private var style: PagedTabBar.BadgeStyle = .count(0)

    func apply(_ style: PagedTabBar.BadgeStyle) {
        self.style = style
        defer { applyFill() }
        switch style {
        case .count(let count):
            // Past 99 the pill would out-measure its own segment title.
            label.text = count > 99 ? "99+" : String(count)
            label.isHidden = false
            // Height first, then width — `measuredWidth` reads the height as its
            // floor, so a stale height would round a one-digit pill to the wrong
            // size for one layout pass.
            pillHeight.constant = height
            pillWidth.constant = measuredWidth
        case .dot:
            // ⚠️ The label is hidden AND the size is stated. A hidden view
            // still participates in Auto Layout outside a stack view, so a
            // pill sized by its label would keep sizing to a number nobody can
            // see — a "dot" as wide as the count it replaced.
            label.isHidden = true
            pillWidth.constant = Self.dotDiameter
            pillHeight.constant = Self.dotDiameter
        }
        invalidateIntrinsicContentSize()
    }

    /// The badge's fill: notification red, whichever mark it is.
    ///
    /// **Red is what this app already calls "a number of things waiting".** The
    /// bottom tab bar's badges are the system's own red, and the count pills in
    /// For You's mode menu are drawn to match them. A tab capsule sitting a
    /// finger's width above that bar, saying the same kind of thing in a
    /// different colour, made the viewer resolve two palettes to learn one
    /// fact.
    ///
    /// ⚠️ **This was the accent for one revision, on the argument that the same
    /// number appears on the avatar of every row it counts and those badges are
    /// the accent.** That argument is real and it lost: matching DOWN to the
    /// bar the tabs live on beats matching ACROSS to the rows they summarise,
    /// because the bar is the thing a viewer sees in the same glance. The cost
    /// is stated rather than hidden — a count is red on the tab and blue on the
    /// row it counts, and `BadgedAvatarView` is where that would be reconciled
    /// if it ever should be.
    ///
    /// ⚠️ **A count used to be chrome** — it followed its segment's selection,
    /// brightening from `secondaryLabel` to `label` alongside the title it
    /// belonged to, so a row of counts read as one control. It is not chrome any
    /// more, and what goes with it is deliberate: an unselected tab no longer
    /// dims its count, because a count on the tab you are NOT looking at is
    /// exactly the one worth noticing. That is the argument the dot has always
    /// made for itself, and both marks now make it together.
    ///
    /// ⚠️ A semantic colour inside a `UIGlassEffect` content view — the
    /// arrangement that once resolved `.systemBackground` to the wrong end of
    /// the spectrum in dark mode (see the type comment) — so it was checked in
    /// both appearances rather than reasoned about.
    private func applyFill() {
        switch style {
        case .count:
            backgroundColor = .systemRed
        case .dot:
            backgroundColor = .systemRed
        }
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
