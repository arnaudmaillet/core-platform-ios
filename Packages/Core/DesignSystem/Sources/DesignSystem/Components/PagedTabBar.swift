import UIKit

/// A floating Liquid Glass tab capsule that tracks a horizontal pager: a lens
/// slides between segments in step with the pages beneath it.
///
/// Built for the Messages inbox (All / Requests / Suggestions) and reused
/// unchanged by the For You grid (Discover / Following). It knows nothing about
/// either — it takes titles and reports an index, so a third host is a `titles`
/// array and two closures.
///
/// ⚠️ **NO HOST WEARS IT AS `navigationItem.titleView` ANY MORE.** This said
/// "all three hosts" do, and named Messages, For You and the relationship
/// lists; every selector left the navigation bar in the migration that ended
/// on 2026-09-10. They are in a `UITabAccessory` above the tab bar (For You,
/// Messages, the profile tab root, the place page) or a `UIBarButtonItem` in
/// the stack's bottom toolbar (search results, relationship lists, a pushed
/// profile). `.navigationTitle` still carries the measured constants and is
/// still the right style for both — it is the HUGGING style, and the name is
/// now historical. `.floating` is the original arrangement, still complete, and
/// has no host today, so treat its numbers as unverified against real
/// content.
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
/// **The pill is grabbable**, and that is the one place the bar talks back:
/// a touch that lands on the SELECTION PILL drags it, `onScrub` reports where
/// it has got to, and the host runs its pager under the finger — so the same
/// `setProgress` loop answers a drag on the bar, a swipe on the pages and a
/// tap on a segment. A drag that starts anywhere ELSE on the capsule scrolls
/// the strip, which is what every drag used to do. See "Moving between tabs".
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
        /// **8pt, on every host.** The two ends were 6 and 8 for a while, on
        /// the argument that a filled badge ends exactly where it is drawn
        /// where a letter carries its own side bearing — true, but it left the
        /// contents 1pt off centre, and a tab bar's segments are read as a row.
        ///
        /// ⚠️ **A title view used to take 7/7, and that was a budget, not a
        /// design.** 8/8 needs 263pt against a slot the navigation bar caps at
        /// 258, so the odd point was shaved to buy the fit. Now that a crowded
        /// strip scrolls rather than truncates, there is no fit to buy: the bar
        /// asks for the padding it wants and slides if the slot is smaller.
        /// Both styles read 8.
        var leadingInset: CGFloat { Spacing.sm }

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

        /// The segment titles' type ramp — **one size for every host**.
        ///
        /// `.subheadline` (15pt), the size UIKit gives a sub-navigation
        /// selector and the size the rest of this app's secondary chrome uses.
        ///
        /// ⚠️ **A title view used to take `.footnote` (13pt), and that history
        /// matters.** It was never a type decision: at 15pt the bar's content
        /// did not FIT the title slot — measured on the Messages inbox at 261pt
        /// of a slot topping out near 252 — and back then overflow TRUNCATED,
        /// taking the selected title first. 13pt bought the ~23pt that made
        /// three titles fit. Once the strip started scrolling its overflow (see
        /// the `content.widthAnchor` constraint) that pressure disappeared: a
        /// bar too wide for its slot now slides instead of clipping, so the
        /// only thing 13pt still bought was smaller text. Every host reads at
        /// 15pt now, and a crowded one scrolls.
        var titleTextStyle: UIFont.TextStyle { .subheadline }

        /// Where Dynamic Type stops growing the titles.
        ///
        /// A FLOATING bar has room to give and grows to 19pt before it stops.
        ///
        /// A TITLE VIEW does not grow at all — 15 is `.subheadline`'s own base
        /// size, so the cap is reached before the first step. **The reason
        /// changed with the move to 15pt** and is worth restating: it is no
        /// longer width (the strip scrolls) but the row it sits in. A
        /// navigation bar's title and its button items are fixed-size chrome,
        /// so a capsule that grew between them would be the only thing on the
        /// row that moved — and it would grow inside a fixed 44pt capsule,
        /// where the lens runs out of VERTICAL room long before the strip runs
        /// out of horizontal.
        ///
        /// ⚠️ Still a real trade: viewers on large text sizes get tab titles
        /// at 15pt. It is the same bargain UIKit strikes for every navigation
        /// bar, and the CONTENT beneath still scales — but it is a bargain.
        var maximumTitlePointSize: CGFloat {
            switch self {
            case .floating: 19
            case .navigationTitle: 15
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
        /// How far a finger has to travel before a press on the pill stops
        /// being a tap. Small: the pill is dragged from a standstill, so the
        /// first few points are the ones that have to feel connected.
        static let dragSlop: CGFloat = 3
        /// How close to either end of the capsule a dragging finger has to be
        /// before the strip starts scrolling under it. Wide enough to reach
        /// with the pill still fully visible, narrow enough that a drag across
        /// the middle of a crowded strip never triggers it.
        static let edgeZone: CGFloat = 36
        /// The fastest the strip travels while a finger is pressed into the
        /// corner, in points per second. A five-tab strip overruns its capsule
        /// by about 60pt, so this crosses the whole overrun in a beat while
        /// still being a scroll the eye can follow.
        static let edgeScrollSpeed: CGFloat = 520
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
    /// Renders the bar BARE, for a host that already composites what it holds.
    ///
    /// ⚠️ Exists for one host: a `UIBarButtonItem(customView:)`. UIKit gives bar
    /// items the system's own glass capsule — "bar items get a capsule, the
    /// title slot gets nothing" — so a bar carrying its own backdrop there is a
    /// glass lens inside a glass capsule, the arrangement that cost the lens its
    /// edge entirely (see the type comment). The title slot is the opposite case
    /// and must keep its backdrop.
    /// The width of the FIRST segment, plus the capsule's own padding — the
    /// least width at which this bar still says something: one whole tab,
    /// legible, with every other reachable by scrolling.
    public var firstSegmentWidth: CGFloat {
        guard let first = segments.first else { return capsulePadding * 2 }
        return ceil(first.pinnedWidth) + capsulePadding * 2
    }

    #if DEBUG
    /// How many segments the bar carries, so an audit can hit-test each one
    /// without reaching into the private row.
    public var debugSegmentCount: Int { segments.count }

    /// Every segment's laid-out frame, in THIS BAR's coordinate space, in order.
    ///
    /// ⚠️ **AN AUDIT THAT DIVIDES THE BAR BY `count` IS ASSUMING AN
    /// ARRANGEMENT.** That was true while every segment was as wide as the
    /// widest; it stops being true the moment the bar hands out natural widths,
    /// and the probe points then drift off the outer segments and report a
    /// working strip as blocked. Real frames are the only thing that survives a
    /// distribution change.
    public var debugSegmentFrames: [CGRect] {
        segments.map { $0.convert($0.bounds, to: self) }
    }

    /// Every segment's laid-out width, in order.
    ///
    /// ⚠️ THE DISTRIBUTION IS INVISIBLE IN A SCREENSHOT OF A FITTING BAR — every
    /// arrangement looks plausible until a title is long enough to inflate the
    /// short ones. These are the widths that say which arrangement is actually
    /// running.
    public var debugSegmentWidths: [CGFloat] { debugSegmentFrames.map(\.width) }
    #endif

    public var suppressesBackdrop: Bool = false {
        didSet {
            guard suppressesBackdrop != oldValue else { return }
            if suppressesBackdrop {
                capsule.effect = nil
            } else {
                materializeEffects()
            }
            applyCapsulePadding()
        }
    }

    /// The lens's clearance inside THIS VIEW — which is not the clearance the
    /// viewer sees when something else is drawing the capsule.
    ///
    /// ⚠️ **Zero when a bar item's platter supplies the pill, and that is not a
    /// missing margin.** The platter is 4pt larger than the view it hosts on
    /// every side (measured: a 149×36 host in a 157×44 platter), so a lens inset
    /// 4pt inside the view lands **8pt** inside the pill the viewer actually
    /// sees — twice the clearance the same bar shows inline on the profile, and
    /// visibly chunkier. Standing the lens on this view's own edge puts the
    /// platter's overhang in the margin's place and the two read identically.
    ///
    /// The radii agree by construction: the lens is a capsule of its own height,
    /// so a 36pt lens centred in a 44pt pill is concentric with it (18 = 22 − 4).
    private var lensInset: CGFloat { suppressesBackdrop ? 0 : Metrics.lensInset }

    /// The same clearance on the horizontal axis — between the capsule's edge
    /// and the first segment.
    private var capsulePadding: CGFloat { lensInset }

    public var fillsWidth: Bool = false {
        didSet {
            guard fillsWidth != oldValue, style.hugsContent else { return }
            applyRowArrangement()
        }
    }

    /// How the segments divide the room the bar has.
    ///
    /// ⚠️ **A THIRD AXIS, BECAUSE `fillsWidth` WAS CARRYING TWO ANSWERS.** That
    /// Bool means "the host owns my width now" — it is what makes the bar
    /// report `noIntrinsicMetric` — and it was ALSO deciding that the segments
    /// share the room equally. The two came apart the moment one host wanted
    /// the second answer changed without the first: an accessory's width is
    /// UIKit's in both environments (measured: a required width constraint on
    /// the content view is inert), so the bar must go on spanning while the
    /// segments stop being uniform.
    public enum SegmentSizing: Sendable {
        /// Every segment as wide as the widest — one balanced control, and the
        /// right answer whenever the bar has room to spare.
        case equalSlots
        /// Every segment as wide as its own title — "All" narrower than
        /// "Requests" — **but only when equal slots would not fit**.
        ///
        /// ⚠️ **THE CONDITION IS THE WHOLE POINT, AND IT WAS MISSING.** Natural
        /// widths hug, and a hugged row centres itself in a slot it does not
        /// fill: filmed on For You's inline band, "Discover" and "Following"
        /// want 171pt of a 226pt slot and sat with ~27pt of dead glass at each
        /// end, inside a capsule UIKit keeps 234pt wide whatever the row does.
        /// So this asks first — if the equal-slot arrangement fits, it stays,
        /// because filling the glass is what makes the band read as one
        /// control. Measured against the three real strips at 226pt: For You's
        /// equal slots want ~202 and stay, the inbox's want ~298 and give way,
        /// the profile's five want ~333 and give way.
        case naturalWhenCrowded
    }

    /// Defaults to `.equalSlots`, which is what every host had before this
    /// existed — so a host that never sets it is unchanged by construction.
    public var segmentSizing: SegmentSizing = .equalSlots {
        didSet {
            guard segmentSizing != oldValue else { return }
            applyRowArrangement()
        }
    }

    /// Whether the bar is currently taking its width from its host rather than
    /// stating one — true for a floating bar always, and for a hugging bar that
    /// has been told to fill.
    private var spansItsHost: Bool { !style.hugsContent || fillsWidth }

    /// Whether the row is pinned to both content edges with its segments
    /// sharing the width equally — the arrangement `fillsWidth` alone used to
    /// imply.
    ///
    /// ⚠️ THE TWO HALVES MUST MOVE TOGETHER. `.fill` with the row pinned at
    /// BOTH ends hands all the slack to one arbitrary segment: measured, "All"
    /// came out 52pt wide where its content needed 36, and its selection read
    /// as an oval instead of a disk. Natural widths therefore centre the row
    /// (`rowHugsConstraints`) rather than stretching it.
    private var spreadsSegments: Bool {
        guard spansItsHost else { return false }
        switch segmentSizing {
        case .equalSlots:
            return true
        case .naturalWhenCrowded:
            // ⚠️ The test is on the arrangement being LEFT, not the one being
            // taken. "Do the natural widths fit?" is the wrong question: a row
            // whose naturals fit at 220 but whose equal slots want 300 would
            // keep equal slots and overflow, when giving way would have fitted.
            // Asking whether EQUAL SLOTS fit can never do that.
            return fittedWidth(for: .fillEqually) <= bounds.width + 0.5
        }
    }

    /// The arrangement currently installed, so a layout pass can tell a real
    /// change from the answer it already applied.
    ///
    /// ⚠️ WITHOUT THIS, `layoutSubviews` RE-APPLIES ON EVERY PASS, and
    /// `applyRowArrangement` ends with `setNeedsLayout()` — a loop that never
    /// settles.
    private var appliedSpread: Bool?

    /// How the row divides itself RIGHT NOW.
    private var activeDistribution: UIStackView.Distribution {
        spreadsSegments ? .fillEqually : style.segmentDistribution
    }

    /// Re-states the row's distribution and its pinning together.
    ///
    /// ⚠️ THROUGH `setNeedsLayout()`, NEVER A DIRECT `applyProgress()`. The lens
    /// is built from `segments[i].frame`, and every path except
    /// `SegmentRow.layoutSubviews` reads those one pass stale — the shipped
    /// defect was a badge arriving while the segments still carried their old
    /// frames, which drew "99" permanently outside its own pill.
    private func applyRowArrangement() {
        appliedSpread = spreadsSegments
        row.distribution = activeDistribution
        NSLayoutConstraint.deactivate(spreadsSegments ? rowHugsConstraints : rowFillsConstraints)
        NSLayoutConstraint.activate(spreadsSegments ? rowFillsConstraints : rowHugsConstraints)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private var rowHugsConstraints: [NSLayoutConstraint] = []
    private var rowFillsConstraints: [NSLayoutConstraint] = []
    /// The row constraints whose constant IS `capsulePadding`, kept so a change
    /// of host can re-state it — see `applyCapsulePadding`.
    private var paddedLeadingConstraints: [NSLayoutConstraint] = []
    private var paddedTrailingConstraints: [NSLayoutConstraint] = []

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

    /// The pill is being dragged, reported as a fractional page position.
    ///
    /// The exact mirror of `setProgress`: one `CGFloat` in logical page units,
    /// every frame of the finger. The owner scrubs its pager to it, and the
    /// pager reports back through `setProgress` — so the lens is still driven
    /// by the pages even while the finger is what is moving them, and the two
    /// cannot disagree.
    ///
    /// ⚠️ **A drag never announces `.valueChanged`.** Where the pages land is
    /// the PAGER's answer, not the bar's: the release hands over a velocity and
    /// the pager decides whether a flick carries to the next page, then reports
    /// its landing through the channel every host already listens to
    /// (`onSettled` / `onPageSettled`). A bar that also announced would commit
    /// the model twice, to two answers, in an order nobody chose.
    public var onScrub: ((CGFloat) -> Void)?

    /// The pill was let go, with the drag's speed in PAGES PER SECOND — signed,
    /// so the owner can let a flick carry to the next page instead of falling
    /// back to whichever one it is nearest.
    ///
    /// Left nil, the lens settles itself. That is the honest fallback rather
    /// than a defect: with no pager on the other end there is no animation to
    /// ride home, so the bar runs its own.
    public var onScrubEnd: ((CGFloat) -> Void)?

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
    /// The grab. A zero-duration long press, not a pan — see `handlePillGrab`.
    private let pillGrab: UILongPressGestureRecognizer = {
        let grab = UILongPressGestureRecognizer()
        grab.minimumPressDuration = 0
        // The default cancels a press that travels, and travelling is the point.
        grab.allowableMovement = .greatestFiniteMagnitude
        // ⚠️ FALSE, deliberately, where the two precedents for this recognizer
        // (`MediaPageIndicatorView`, `SnapMediaPageBarView`) both set it true.
        // Cancelling here would take the touch away from the SegmentView under
        // it, and a tap on the selected tab is a real request — the profile
        // scrolls its gallery back to the top on it. The drag takes the touch
        // away by hand instead, and only once it has actually moved: see
        // `cancelSegmentTracking`.
        grab.cancelsTouchesInView = false
        // ⚠️ AND NEITHER DELAY, which is not the default: a long press ships
        // with `delaysTouchesEnded = true`, so the touch-UP it declines is held
        // back from the view until it has resolved. Measured with a real finger
        // (`PillDragUITests`): a tap on a segment the pill is not on selected
        // nothing at all, because the button under it never received the end of
        // the touch it was tracking.
        grab.delaysTouchesBegan = false
        grab.delaysTouchesEnded = false
        return grab
    }()
    /// Live only while a finger owns the pill.
    private var pillDrag: PillDrag?
    #if DEBUG
    /// How many times the grab has taken a touch, and how many taps have
    /// reached a segment — the two halves of the arbitration, counted, because
    /// "the tap did nothing" and "the tap never happened" look identical from
    /// outside.
    public private(set) var debugGrabsBegun = 0
    public private(set) var debugTapsReceived = 0
    public private(set) var debugLastBeginTest = ""
    #endif
    /// Runs for the length of a drag; scrolls the strip while the finger is
    /// held against either end of the capsule. See `stepEdgeScroll`.
    private var edgeScrollLink: CADisplayLink?

    /// One finger's grip on the selection pill.
    ///
    /// Positions are kept in the VIEWPORT's space (the capsule's), not the
    /// scroll content's, because the content moves underneath a drag that
    /// reaches the ends — a finger held perfectly still is at the same viewport
    /// x every frame and at a different content x every frame, and only one of
    /// those two facts is about the finger.
    private struct PillDrag {
        /// Finger minus pill centre, in CONTENT points, taken once at touch-down
        /// and never re-taken: the pill keeps the grip it was picked up by, so a
        /// pill grabbed near its edge does not jump its centre under the finger.
        var grab: CGFloat
        /// Where the finger went down, for the slop test that separates a tap
        /// from a drag.
        var start: CGFloat
        /// Where the finger is now.
        var touch: CGFloat
        /// The last progress and the moment it was sampled — the two numbers a
        /// release velocity is made of, since a long press reports none.
        var lastProgress: CGFloat
        var lastMoment: CFTimeInterval
        /// Pages per second, low-passed: a single frame's sample is noisy
        /// exactly when it matters, because the last frame before a lift is
        /// usually the slowest one.
        var speed: CGFloat
        /// Whether the finger has travelled far enough to have stopped being a
        /// tap.
        var moved: Bool
    }
    /// What the strip looked like the last time it was asked whether the
    /// selection needed revealing: the selection, the viewport it sits in, and
    /// the content it sits on. A layout pass that changes NONE of these must not
    /// undo a scroll the viewer made by hand — see `keepLensVisible`.
    private var lastSeenStripGeometry: StripGeometry?

    private struct StripGeometry: Equatable {
        var progress: CGFloat
        var viewportWidth: CGFloat
        var contentWidth: CGFloat
    }

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
        // The strip reveals the selected tab from HERE, not from the bar's own
        // layout — the viewport is only final once the scroll view has been
        // sized. See `StripScrollView.onLayout`.
        scroller.onLayout = { [weak self] in self?.keepLensVisible() }
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
        let hugsLeading = row.leadingAnchor.constraint(
            greaterThanOrEqualTo: content.leadingAnchor, constant: capsulePadding
        )
        let hugsTrailing = row.trailingAnchor.constraint(
            lessThanOrEqualTo: content.trailingAnchor, constant: -capsulePadding
        )
        rowHugsConstraints = [
            hugsLeading, hugsTrailing,
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        ]
        let fillsLeading = row.leadingAnchor.constraint(
            equalTo: content.leadingAnchor, constant: capsulePadding
        )
        let fillsTrailing = row.trailingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: -capsulePadding
        )
        rowFillsConstraints = [fillsLeading, fillsTrailing]
        // ⚠️ Held by NAME, because `capsulePadding` is not a constant here:
        // `suppressesBackdrop` is set by the host AFTER init (a bar item's
        // platter supplies the pill), and it takes the padding to zero. Without
        // these the row keeps the 4pt it was built with and only the lens moves,
        // which is half a change and looks like a bug.
        paddedLeadingConstraints = [hugsLeading, fillsLeading]
        paddedTrailingConstraints = [hugsTrailing, fillsTrailing]
        NSLayoutConstraint.activate(spreadsSegments ? rowFillsConstraints : rowHugsConstraints)

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


        // The grab, on the BAR — where the previous drag was on
        // `capsule.contentView`, which is a subview and therefore invisible to
        // the test that forbade it.
        //
        // ⚠️ **THE DELEGATE IS LOAD-BEARING, and `UIView`'s own
        // `gestureRecognizerShouldBegin` override is NOT ENOUGH.** Measured
        // with a real finger, against a probe counting both halves: a tap on a
        // segment the pill was not on reported `grabs=1 taps=0 begin=[]` — the
        // grab took the touch, the segment never got its tap, and the policy
        // that would have refused was never asked. It is the DELEGATE method
        // UIKit consults here; the view method of the same name is not called
        // for this recognizer. (Which is why the drag this replaces set a
        // delegate too, and why the file kept a bare conformance for it.)
        pillGrab.addTarget(self, action: #selector(handlePillGrab))
        pillGrab.delegate = self
        addGestureRecognizer(pillGrab)

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
        return ceil(total + spacing) + capsulePadding * 2
    }

    /// Materialized in-window, never in init: creating a real effect off
    /// screen stalls the render server on headless CI simulators (the same
    /// rule `ChatInputBar` and `SnapGlassCardView` follow).
    private func materializeEffects() {
        guard window != nil, style.carriesBackdrop, !suppressesBackdrop else { return }
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
        // ⚠️ **DECIDED HERE, BECAUSE IT DEPENDS ON A WIDTH.** `.naturalWhenCrowded`
        // asks whether the equal-slot arrangement fits, and nothing knows that
        // until the bar has been given its bounds — which for an accessory
        // changes underneath it, 360pt expanded and 234 docked, with no
        // callback but this one.
        let spread = spreadsSegments
        if spread != appliedSpread {
            appliedSpread = spread
            applyRowArrangement()
        }
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
        // ⚠️ **A DRAG DOES NOT SURVIVE THE SCREEN IT WAS ON.** A `CADisplayLink`
        // RETAINS its target, so a bar that goes away mid-drag — a pop, a tab
        // change, a selector swapped for another screen's — would be kept alive
        // by the end-of-strip scroller, ticking, for the life of the app. The
        // recognizer's own `.cancelled` covers the ordinary case; this covers
        // the one where the view is simply taken out of the window.
        if window == nil, pillDrag != nil { endPillDrag() }
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
        #if DEBUG
        if fromTap { debugTapsReceived += 1 }
        #endif
        guard index != selectedIndex else {
            if fromTap { onReselect?(index) }
            return
        }
        selectedIndex = index
        sendActions(for: .valueChanged)
    }

    // MARK: - Moving between tabs
    //
    // Three ways now, and ONE SENTENCE tells them apart:
    //
    //   * a touch that goes down on the SELECTION PILL drags it, and the pages
    //     run under the finger;
    //   * any other drag scrolls the strip;
    //   * a press that does not travel is a tap, wherever it landed.
    //
    // ⚠️ **This bar carried a drag once and it was removed** (commit
    // 6f8b6a0, "Take the third gesture off the tab bar"). Worth reading before
    // touching this, because the complaint was not that a draggable capsule is
    // a bad idea — it is that THAT one could not be described: it could be
    // grabbed anywhere, so it had to stand down whenever the strip had
    // somewhere to scroll, and the same finger on the same control therefore
    // did one thing on three tabs and another on five. "Three recognizers
    // arbitrating one finger produced behaviour no rule could state simply."
    //
    // What is different is the discriminator. It is now WHERE the touch lands,
    // not WHETHER the strip overflows: the pill is a thing on the screen, it is
    // in one place, and everywhere else belongs to the scroll view. That holds
    // at three tabs and at five, and it is the rule a viewer can learn without
    // being told — the pill is grabbable because it is the object being moved.
    //
    // The vertical half of the old complaint is answered by the recognizer's
    // own reach: it begins only inside the capsule, and the capsule is not
    // something the page underneath scrolls through.

    /// Whether a touch here picks up the pill.
    ///
    /// ⚠️ **Against `lens.frame`, NOT `segments[selectedIndex]`, and mid-flight
    /// those are different rectangles.** `selectedIndex` flips at the half-way
    /// point of a page change while the pill is still interpolating between two
    /// segments — at progress 1.6 the index reads 2 and the pill is drawn
    /// mostly over segment 1. The premise of this gesture is "the finger landed
    /// on the pill", so the pill is what it asks about.
    ///
    /// Vertically the whole capsule counts. The pill is inset 4pt top and
    /// bottom, and demanding those 4pt would make a grab fail for reasons the
    /// viewer cannot see.
    /// Split in two for the trace alone: the answer and the numbers behind it
    /// are what a probe has to report, and this decision is made in a place
    /// (inside a delegate callback, mid-touch) where nothing else can see it.
    /// The first version of this gesture shipped a policy UIKit was never
    /// asking — `grabs=1 taps=0 begin=[]` is what said so, and only the last
    /// field said WHICH of the three possible faults it was.
    private func beginsPillDrag(at point: CGPoint) -> Bool {
        let answer = decidePillDrag(at: point)
        #if DEBUG
        debugLastBeginTest = String(format: "pt=%.0f,%.0f pill=%.0f-%.0f off=%.0f vp=%.0fx%.0f->%d",
                                    point.x, point.y, lens.frame.minX, lens.frame.maxX,
                                    scroller.contentOffset.x,
                                    capsule.contentView.bounds.width,
                                    capsule.contentView.bounds.height, answer ? 1 : 0)
        #endif
        return answer
    }

    private func decidePillDrag(at point: CGPoint) -> Bool {
        guard isEnabled, segments.count > 1 else { return false }
        let viewport = capsule.contentView.bounds
        guard viewport.width > 0, viewport.contains(point) else { return false }
        let pill = lens.frame
        guard pill.width > 0 else { return false }
        let x = point.x + scroller.contentOffset.x
        return x >= pill.minX && x <= pill.maxX
    }

    /// The policy, reached as `pillGrab`'s DELEGATE — see the note at the
    /// recognizer's installation for what happens without that, and how it was
    /// measured. It is an `override` in the class body because `UIView` already
    /// declares this method and Swift will not let an extension override it;
    /// the conformance at the foot of the file is what routes the delegate call
    /// here. Anything that is not ours goes back to `super`, which is
    /// `UIControl`'s own arbitration.
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pillGrab else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return beginsPillDrag(at: pillGrab.location(in: capsule.contentView))
    }

    /// The drag itself.
    ///
    /// ⚠️ **A ZERO-DURATION LONG PRESS, NOT A PAN**, and the file this is
    /// copied from says why in as many words (`MediaPageIndicatorView`): a pan
    /// must see MOVEMENT before it begins, and every scroll view above is
    /// watching for the same movement, so the ancestor claims it every time. A
    /// long press with no minimum duration begins on TOUCH-DOWN — before the
    /// strip's own pan has anything to go on — and then reports `.changed` for
    /// every movement, which is a scrubber exactly.
    ///
    /// Beginning that early is also what makes the rule above enforceable: the
    /// question "did this touch land on the pill" has an answer at touch-down
    /// and only a guess ten points later.
    @objc private func handlePillGrab(_ grab: UILongPressGestureRecognizer) {
        switch grab.state {
        case .began:
            #if DEBUG
            debugGrabsBegun += 1
            #endif
            let x = grab.location(in: capsule.contentView).x
            pillDrag = PillDrag(
                grab: x + scroller.contentOffset.x - lens.frame.midX,
                start: x, touch: x,
                lastProgress: progress, lastMoment: CACurrentMediaTime(),
                speed: 0, moved: false
            )
            // ⚠️ **THE STRIP STANDS DOWN, and it is a lock rather than a
            // `require(toFail:)` edge.** Two things say so. The recorded one:
            // `require(toFail:)` into a scroll view's recognizer graph formed a
            // requirement cycle that froze a whole subtree once already
            // (`SnapShortcutRailView`), and the replacement it settled on is
            // this — suspend the competing scroller for the life of the
            // gesture. The local one: `keepLensVisible` refuses to move a strip
            // that reports `isDragging`, so a scroller left live enough to
            // begin its own pan would silently switch off the end-of-strip
            // scrolling this drag depends on.
            //
            // A disabled scroll view still takes a `contentOffset` assignment,
            // which is the only way this drag moves it anyway.
            scroller.isScrollEnabled = false
            startEdgeScroll()
        case .changed:
            guard let drag = pillDrag else { return }
            let x = grab.location(in: capsule.contentView).x
            if !drag.moved, abs(x - drag.start) > Metrics.dragSlop { cancelSegmentTracking() }
            trackPill(to: x)
        case .ended, .cancelled, .failed:
            endPillDrag()
        default:
            break
        }
    }

    /// Puts the pill where the finger is, and tells the pages.
    ///
    /// Called from the finger AND from the edge scroller, because those are two
    /// ways for the same relationship to change: the finger moves over a still
    /// strip, or the strip moves under a still finger. Either way the pill is
    /// wherever the grip says it is.
    private func trackPill(to viewportX: CGFloat, at now: CFTimeInterval = CACurrentMediaTime()) {
        guard var drag = pillDrag, segments.count > 1 else { return }
        let centre = viewportX + scroller.contentOffset.x - drag.grab
        let target = pageProgress(forPillCentre: centre)

        let elapsed = now - drag.lastMoment
        if elapsed > 0.002 {
            let sample = (target - drag.lastProgress) / CGFloat(elapsed)
            drag.speed = drag.speed * 0.4 + sample * 0.6
            drag.lastProgress = target
            drag.lastMoment = now
        }
        drag.moved = drag.moved || abs(viewportX - drag.start) > Metrics.dragSlop
        drag.touch = viewportX
        pillDrag = drag

        guard target != progress else { return }
        progress = target
        // ⚠️ Directly, not through `setNeedsLayout()`. The rule this looks
        // like it breaks — "a geometry change must reach the lens through a
        // layout pass, never by calling `applyProgress` directly" — is about
        // reading segment frames that a stack view has not placed yet. Nothing
        // here changes a segment's size: the titles, the badges and the widths
        // are all exactly what the last layout pass left, and only the
        // interpolation between them moves. `setProgress` takes the same path
        // for the same reason, on every frame of every swipe.
        applyProgress()
        onScrub?(target)
    }

    /// The finger let go.
    ///
    /// The bar does not decide where the pages land — it hands over how fast
    /// the pill was going and the pager commits, exactly as it does for its own
    /// released swipe. What comes back is `onProgress`, frame by frame, all the
    /// way home: the lens rides the settle animation instead of running one of
    /// its own, which is the same "ONE animation drives both" every host's tap
    /// handler already relies on.
    private func endPillDrag() {
        guard let drag = pillDrag else { return }
        pillDrag = nil
        stopEdgeScroll()
        scroller.isScrollEnabled = true
        // ⚠️ **A press that never travelled is a TAP, and a tap is the
        // segment's business — nothing was scrubbed, so there is nothing to
        // settle.** Publishing one anyway is not harmless: every tap on the
        // selected tab would ask its pager to re-commit to the page it is
        // already on, and the profile's does real work there (it re-aligns the
        // landing page's vertical offset, which above the dock line can move a
        // page the viewer was reading). It would also cancel the tracking that
        // makes the tap a tap — `onReselect`, which is how the profile's
        // gallery scrolls back to the top.
        guard drag.moved else { return }
        cancelSegmentTracking()
        if let onScrubEnd {
            onScrubEnd(drag.speed)
        } else {
            settleLensAlone(speed: drag.speed)
        }
    }

    /// No pager on the other end — a bar in a test, an audit, or a host that
    /// has not wired `onScrubEnd`. There is no settle animation to ride, so the
    /// lens runs one, using the same throw the pagers use so the landing is the
    /// same number either way.
    private func settleLensAlone(speed: CGFloat) {
        let landing = landingIndex(from: progress, speed: speed)
        guard CGFloat(landing) != progress else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.setProgress(CGFloat(landing))
        }
    }

    /// Where a release commits: half a page of throw per unit of velocity —
    /// enough that a flick carries, small enough that a slow drag released
    /// mid-way falls back to whichever page it is actually nearest.
    ///
    /// The same arithmetic the three pagers use in `settleAfterScrub`, stated
    /// here as well so a bar with nothing wired to it lands on the same tab a
    /// wired one would.
    private func landingIndex(from position: CGFloat, speed: CGFloat) -> Int {
        let projected = position + speed * 0.5
        return min(max(Int(projected.rounded()), 0), max(0, segments.count - 1))
    }

    /// ⚠️ **The dragged segment has to stop tracking, or the drag ends as a
    /// TAP.** Every segment is a `UIButton` and this recognizer deliberately
    /// does not cancel touches in view, so the button under the finger keeps
    /// tracking for the whole drag: it stays dimmed to 0.55, and a drag that
    /// happens to lift back inside the segment it started in fires
    /// `.primaryActionTriggered` — which on the profile scrolls the gallery to
    /// the top, for a gesture that was never a tap.
    ///
    /// Normally the strip's scroll view does this (`touchesShouldCancel`); this
    /// drag wins the touch instead of it, so it has to do the same job.
    /// Everything is cancelled rather than the one segment tracked, because
    /// which one it is is UIKit's business, and cancelling a control that is
    /// not tracking does nothing.
    private func cancelSegmentTracking() {
        for segment in segments { segment.cancelTracking(with: nil) }
    }

    // MARK: - The ends of the strip

    /// Starts the display link that scrolls the strip while the finger is held
    /// against one of the capsule's ends.
    ///
    /// ⚠️ **`keepLensVisible` is not enough on its own, and it is worth
    /// saying why since it looks like it should be.** It does move the strip
    /// while the pill is dragged past the edge — by the minimum that brings the
    /// pill back into view, which is exactly right — but it is driven by
    /// `applyProgress`, and `applyProgress` only runs when the finger MOVES. A
    /// finger held still at the edge of a crowded strip therefore stops the
    /// world: the tab it is reaching for is two segments away and nothing
    /// brings it closer. The reveal remains the floor under this; the link is
    /// what makes holding at the end mean "keep going".
    private func startEdgeScroll() {
        guard edgeScrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepEdgeScroll))
        // `.common`, so it survives a tracking run loop — which is the only
        // mode this ever runs in, since a finger is down for all of it.
        link.add(to: .main, forMode: .common)
        edgeScrollLink = link
    }

    private func stopEdgeScroll() {
        edgeScrollLink?.invalidate()
        edgeScrollLink = nil
    }

    @objc private func stepEdgeScroll(_ link: CADisplayLink) {
        guard let drag = pillDrag else { return stopEdgeScroll() }
        let speed = edgeScrollSpeed(at: drag.touch)
        guard speed != 0 else { return }
        let reachable = max(0, scroller.contentSize.width - scroller.bounds.width)
        let moved = min(max(0, scroller.contentOffset.x + speed * CGFloat(link.targetTimestamp - link.timestamp)), reachable)
        guard abs(moved - scroller.contentOffset.x) > 0.01 else { return }
        scroller.contentOffset.x = moved
        // The finger has not moved; the strip has. Same grip, new content under
        // it — so the pill advances, and with it the pages.
        trackPill(to: drag.touch)
    }

    /// Points per second, signed, for a finger this far into the capsule.
    ///
    /// Zero everywhere but the two end zones, and ramped inside them, so the
    /// strip creeps when the finger is at the edge and runs when it is pressed
    /// into the corner. A constant rate reads as a lurch the moment you cross
    /// the line.
    private func edgeScrollSpeed(at viewportX: CGFloat) -> CGFloat {
        let width = capsule.contentView.bounds.width
        guard width > Metrics.edgeZone * 2 else { return 0 }
        if viewportX < Metrics.edgeZone {
            let depth = (Metrics.edgeZone - max(0, viewportX)) / Metrics.edgeZone
            return -Metrics.edgeScrollSpeed * min(1, depth)
        }
        if viewportX > width - Metrics.edgeZone {
            let depth = (viewportX - (width - Metrics.edgeZone)) / Metrics.edgeZone
            return Metrics.edgeScrollSpeed * min(1, depth)
        }
        return 0
    }

    /// The inverse of the lens interpolation: which fractional page puts the
    /// pill's centre HERE.
    ///
    /// Centres rather than edges, because the pill's width changes as it travels
    /// between segments of different widths — two of its three landmarks move,
    /// and the middle one is the one the finger is holding.
    ///
    /// ⚠️ Written without assuming the centres INCREASE with the index. A
    /// horizontal stack lays its arranged subviews out leading-to-trailing, so
    /// in a right-to-left language segment 0 is the RIGHTMOST one and every
    /// `x <= centres[i]` test means the opposite of what it reads. The
    /// interpolation below is signed and needs no such assumption; only the
    /// past-the-end case has to ask which end it is.
    private func pageProgress(forPillCentre x: CGFloat) -> CGFloat {
        guard segments.count > 1 else { return 0 }
        let centres = segments.indices.map { lensFrame(for: $0).midX }
        for index in 0..<(centres.count - 1) {
            let from = centres[index], to = centres[index + 1]
            guard x >= min(from, to), x <= max(from, to) else { continue }
            let span = to - from
            guard span != 0 else { return CGFloat(index) }
            return CGFloat(index) + (x - from) / span
        }
        let first = centres[0], last = centres[centres.count - 1]
        let beforeTheFirst = first <= last ? x < first : x > first
        return beforeTheFirst ? 0 : CGFloat(centres.count - 1)
    }

    #if DEBUG
    /// The drag, without a finger.
    ///
    /// A gesture recognizer cannot be driven from a unit test, and the
    /// simulator does not deliver injected touches to a bar in the accessory
    /// band — so the alternative to these is a feature verified by eye. They
    /// enter through the same three functions the recognizer does, and take the
    /// same viewport-space x, so what a test exercises is the shipping path and
    /// not a copy of it.
    public func debugBeginsPillDrag(atViewportX x: CGFloat) -> Bool {
        beginsPillDrag(at: CGPoint(x: x, y: capsule.contentView.bounds.midY))
    }

    public func debugBeginPillDrag(atViewportX x: CGFloat) -> Bool {
        guard debugBeginsPillDrag(atViewportX: x) else { return false }
        pillDrag = PillDrag(
            grab: x + scroller.contentOffset.x - lens.frame.midX,
            start: x, touch: x,
            lastProgress: progress, lastMoment: CACurrentMediaTime(),
            speed: 0, moved: false
        )
        scroller.isScrollEnabled = false
        return true
    }

    /// `after` is how long this frame took, since the velocity a release hands
    /// over is made of distance and time and a test runs both in the same
    /// microsecond — left to the real clock, every scripted drag would report a
    /// flick of several hundred pages per second or none at all.
    public func debugDragPill(toViewportX x: CGFloat, after seconds: CFTimeInterval = 1.0 / 60.0) {
        guard let drag = pillDrag else { return }
        if !drag.moved, abs(x - drag.start) > Metrics.dragSlop { cancelSegmentTracking() }
        trackPill(to: x, at: drag.lastMoment + seconds)
    }

    /// One frame of the end-of-strip scroll, at a stated frame duration — the
    /// display link's own clock is not a thing a test can wait for.
    public func debugStepEdgeScroll(seconds: CGFloat = 1 / 60) {
        guard let drag = pillDrag else { return }
        let speed = edgeScrollSpeed(at: drag.touch)
        guard speed != 0 else { return }
        let reachable = max(0, scroller.contentSize.width - scroller.bounds.width)
        scroller.contentOffset.x = min(max(0, scroller.contentOffset.x + speed * seconds), reachable)
        trackPill(to: drag.touch, at: drag.lastMoment + CFTimeInterval(seconds))
    }

    public func debugEndPillDrag() { endPillDrag() }

    /// Whether the strip is currently standing down for a drag.
    public var debugStripAcceptsScrolling: Bool { scroller.isScrollEnabled }

    /// Where the pill is DRAWN — the capsule's own space, which is what a
    /// finger aims at. `debugLensAlignment` reports the same rectangle in the
    /// scroll content's space, and on a crowded strip those differ by the whole
    /// content offset.
    public var debugPillInViewport: CGRect {
        lens.frame.offsetBy(dx: -scroller.contentOffset.x, dy: 0)
    }

    /// The width a dragging finger has to work in.
    public var debugViewportWidth: CGFloat { scroller.bounds.width }

    /// Where the pill and the strip are in SCREEN points — what a UITest has to
    /// aim at, since the only honest test of the arbitration is a real finger
    /// and a real finger is placed in screen coordinates.
    public var debugPillOnScreen: CGRect { lens.convert(lens.bounds, to: nil) }

    public var debugStripOnScreen: CGRect {
        capsule.contentView.convert(capsule.contentView.bounds, to: nil)
    }
    #endif

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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-tabbar-shape-trace") {
            print(String(format: "[lens-follow] p=%.2f seen=%@ content=%.1f scroller=%.1f "
                         + "capsule=%.1f self=%.1f lens=%.1f@%.1f offset=%.1f dragging=%@",
                         progress,
                         lastSeenStripGeometry.map { String(format: "%.0f/%.0f", $0.viewportWidth, $0.contentWidth) } ?? "nil",
                         scroller.contentSize.width, scroller.bounds.width,
                         capsule.bounds.width, bounds.width,
                         lens.frame.width, lens.frame.minX, scroller.contentOffset.x,
                         scroller.isDragging || scroller.isDecelerating ? "yes" : "no"))
        }
        #endif
        // ⚠️ **A REAL VIEWPORT FIRST, and this order is the whole bug.** The
        // overflow test below is `content > bounds`, which is trivially true
        // while `bounds` is still zero — so the first layout pass after the
        // segments exist passed it, decided against a scroll view with no size,
        // and left the strip where it was. Measured on a pushed profile's docked
        // selector at 375pt: `content=198 bounds=0`, then `content=198
        // bounds=198`, and "Short" sat outside a capsule showing "Activity
        // Gallery" for the life of the screen. It never showed on a 402pt bar
        // because the strip fits there and has nothing to reveal.
        guard scroller.bounds.width > 0 else { return }
        // ⚠️ **WHAT CHANGED SINCE LAST TIME, not what we last acted on.** The
        // reveal is a function of three things — the selection, the viewport,
        // and the content — and re-running it whenever any of them MOVES is what
        // separates "the world changed" from "something laid out". Recording
        // every geometry we see, rather than only the ones we acted on, is the
        // part that took two attempts:
        //
        // The profile's selector docks at 149pt, undocks to 198, and docks again.
        // Revealing at 149 put the strip at offset 49 — correct — and then the
        // undock grew the viewport to 198, where the strip no longer overflows,
        // so UIKit clamped the offset back to 0. Re-docking returned the viewport
        // to 149, and a latch that remembered "we already revealed at 149"
        // skipped it. The offset it was protecting had been thrown away two
        // passes earlier. Measured end to end with `-header-dock-demo`.
        //
        // A viewer's own scroll moves NONE of these three, so it still survives
        // a layout pass, which is what this guard exists for.
        let geometry = StripGeometry(
            progress: progress,
            viewportWidth: scroller.bounds.width,
            contentWidth: scroller.contentSize.width
        )
        defer { lastSeenStripGeometry = geometry }
        guard geometry != lastSeenStripGeometry else { return }
        guard scroller.contentSize.width > scroller.bounds.width,
              !scroller.isDragging, !scroller.isDecelerating
        else { return }
        // `Metrics`, not the instance padding: this is how much CONTEXT to
        // reveal beside the lens when scrolling to it, not how far inside the
        // capsule it is drawn. A bare bar's lens stands on its own edge, and
        // revealing it with nothing either side of it would read as clipped.
        // ⚠️ **The offset is COMPUTED, not asked for.** This used to be
        // `scrollRectToVisible`, which is the natural call and does the right
        // arithmetic — but it silently declines from inside the scroll view's
        // own layout pass, which is where the reveal now has to happen (see
        // `StripScrollView.onLayout`). Measured on the profile's docked
        // selector, twice over: `rect=258…321 content=317 viewport=196 →
        // offset=0`, and still `offset=0` once the rect was clamped inside the
        // content. Assigning the offset works from anywhere and needs no
        // agreement with UIKit about what an out-of-bounds rect means.
        //
        // The semantics are the ones the doc above describes and are worth
        // keeping: the MINIMUM distance that brings the lens into view, and
        // nothing at all when it is already there.
        let reveal = lens.frame.insetBy(dx: -Metrics.capsulePadding, dy: 0)
        let viewport = scroller.bounds.width
        var offset = scroller.contentOffset.x
        if reveal.minX < offset {
            offset = reveal.minX
        } else if reveal.maxX > offset + viewport {
            offset = reveal.maxX - viewport
        }
        offset = min(max(0, offset), max(0, scroller.contentSize.width - viewport))
        guard abs(offset - scroller.contentOffset.x) > 0.5 else { return }
        scroller.contentOffset.x = offset
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-tabbar-shape-trace") {
            print(String(format: "[lens-follow] REVEAL rect=%.1f…%.1f content=%.1f viewport=%.1f "
                         + "→ offset=%.1f",
                         reveal.minX, reveal.maxX, scroller.contentSize.width,
                         viewport, scroller.contentOffset.x))
        }
        #endif
    }

    /// Re-states the row's horizontal padding, and everything derived from it.
    ///
    /// Three things move together and leaving any one behind is visible: the
    /// row's own inset, the width the bar ASKS for (which includes that inset
    /// twice), and the lens, which is placed off the segments the row just
    /// moved.
    private func applyCapsulePadding() {
        for constraint in paddedLeadingConstraints { constraint.constant = capsulePadding }
        for constraint in paddedTrailingConstraints { constraint.constant = -capsulePadding }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        applyProgress()
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
            y: row.frame.minY + segment.minY + lensInset,
            width: segment.width,
            height: max(0, segment.height - lensInset * 2)
        )
    }
}

/// Conformance only — the policy is an `override` in the class body, because
/// `UIView` already declares `gestureRecognizerShouldBegin(_:)` and Swift will
/// not let an extension override it.
///
/// ⚠️ Deleting this line does not fail to compile and does not fail a test. It
/// silently stops the pill drag being asked WHETHER it may begin, so the grab
/// takes every touch on the capsule and the segments stop selecting.
extension PagedTabBar: UIGestureRecognizerDelegate {}

// MARK: - The strip

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

    /// ⚠️ **THE authoritative moment for "does this strip overflow".** The same
    /// lesson `SegmentRow.onLayout` records, one level out: the bar reads this
    /// view's bounds from its own `layoutSubviews`, which runs BEFORE this view
    /// has been resized — so when a host caps the bar's width, the bar decides
    /// "nothing to scroll" against the viewport it had a pass ago. Measured on a
    /// pushed profile's docked selector: `capsule=149` while `scroller=198`, the
    /// strip therefore judged 198 ≤ 198 and never revealed the selected tab,
    /// which sat clipped outside a capsule showing the first two.
    ///
    /// `layoutIfNeeded()` on the content does not fix it — the scroll view is
    /// this view's own business and it lays itself out later in the same pass.
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
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
