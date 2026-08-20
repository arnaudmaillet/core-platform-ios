import UIKit

/// What the rest of a navigation bar needs, in points — the arithmetic behind
/// the leading selector's ceiling, kept as plain numbers so the rule can be
/// pinned by a test instead of by a screenshot.
///
/// ⚠️ **The bar NEVER collapses; the selector gives way instead.** UIKit has one
/// answer when a bar's items do not fit: it sweeps a whole group into a `•••`,
/// taking the actions with it. So the selector is treated as the LAST claim on
/// the width — everything else is measured first, and the capsule takes what is
/// left. It is a horizontal scroller, so "what is left" is always enough: down
/// to `bubbleWidth` it is a perfect circle showing one tab and swiping to the
/// rest.
struct LeadingSelectorBudget {
    /// The width UIKit draws a bar item's platter at — the standard 44pt touch
    /// target, which is also the least room a glyph item occupies.
    static let itemWidth: CGFloat = 44
    /// Between two items INSIDE one group's shared pill.
    ///
    /// ⚠️ Not the same as the gap between platters, and the difference is what
    /// collapsed the profile. Two trailing glyphs share a single background there
    /// and the pill measures 115pt, not 88 — charging them 44 each and calling it
    /// done left the selector 27pt too wide, and UIKit answered by sweeping both
    /// actions into a `•••`.
    static let sharedItemSpacing: CGFloat = 27
    /// Between two ADJACENT platters in the same group — For You's compose glyph
    /// and the selector beside it, measured at 12pt apart.
    static let platterGap: CGFloat = 12
    /// Between the leading group and the trailing one.
    ///
    /// ⚠️ Measured, and it is a hard floor rather than breathing room: with the
    /// profile's selector capped at 200 the two groups sat 20pt apart and both
    /// were drawn; at 215 the gap fell to 5 and the trailing pair became a `•••`.
    /// 24 is the smallest gap seen intact — the inbox's, exactly.
    static let interGroupGap: CGFloat = 24
    /// The platter's own inset around the selector: a 267pt capsule rides in a
    /// 275pt platter.
    static let platterPadding: CGFloat = 8
    /// What a TITLED item's platter adds to its word. Measured: the profile's
    /// "Following" is 72pt of text in a 106pt platter.
    static let titledItemPadding: CGFloat = 34
    /// The navigation bar's own margin, at each end.
    static let barMargin: CGFloat = 16

    /// The navigation bar's width.
    var barWidth: CGFloat
    /// Items sharing the LEADING group with the selector, at the width each
    /// wants: a back button, For You's compose glyph. Each gets its own platter,
    /// because the selector's does not share a background.
    var leadingSiblingWidths: [CGFloat] = []
    /// The trailing group, at the width each item wants. One pill holds them all,
    /// which is why they are counted together rather than added to the leading
    /// list.
    var trailingWidths: [CGFloat] = []

    /// Room the rest of the bar needs: margins, both groups, and the gap between
    /// them.
    ///
    /// Each item is charged `max(itemWidth, wanted)`: UIKit will not draw a
    /// platter narrower than the touch target however small its glyph, so
    /// measuring a 20pt image and believing it is how a bar comes out 24pt over
    /// its own width.
    var roomForOtherItems: CGFloat {
        let leading = leadingSiblingWidths.reduce(CGFloat.zero) { total, wanted in
            total + max(Self.itemWidth, wanted) + Self.platterGap
        }
        var trailing = trailingWidths.reduce(CGFloat.zero) { total, wanted in
            total + max(Self.itemWidth, wanted)
        }
        if !trailingWidths.isEmpty {
            trailing += Self.sharedItemSpacing * CGFloat(trailingWidths.count - 1)
            trailing += Self.interGroupGap
        }
        return Self.barMargin * 2 + Self.platterPadding + leading + trailing
    }

    /// The widest the selector may be here.
    ///
    /// ⚠️ **`bubbleWidth` wins a contradiction.** A bar too narrow to leave even
    /// a circle is a bar whose other items have already overrun it, and shrinking
    /// the selector past a bubble buys nothing — a 12pt stub is not a control.
    /// The floor is the capsule's own height, which is the selector's minimum by
    /// definition: as wide as it is tall, one perfect bubble.
    func ceiling(bubbleWidth: CGFloat) -> CGFloat {
        max(bubbleWidth, barWidth - roomForOtherItems)
    }
}

/// The host a `PagedTabBar` lives in when it rides the navigation bar's LEADING
/// item group.
///
/// ⚠️ **It exists to CAP the bar's width, and that is the whole reason.** UIKit
/// silently declines to host a leading custom view that does not fit the room
/// left by the other items: no compression, no `•••` overflow, no warning — the
/// item stays in `leftBarButtonItems`, its custom view is never added to any
/// window, and the capsule is simply absent. Measured three times before the
/// cause was clear: the inbox at 280pt (three long titles), the viewer's own
/// profile at five tabs, and both reading as "the selector vanished" while every
/// other piece of state — item present, not hidden, alpha 1, docked — was right.
///
/// So the bar is given a width it can always have, and it SCROLLS the rest. It
/// already owns a horizontal scroller for exactly this, which is why no title
/// has to be shortened to fit.
///
/// ⚠️ **The room is MEASURED, never declared.** Each surface used to hand over a
/// `roomForOtherItems` constant, and the number was bounded at both ends by a
/// cliff nobody could see: too small and the titles clipped, too large and the
/// whole group became a `•••`. The inbox's was tuned to 110 against a measured
/// band of [86, 131] on two specific devices — a number already wrong for a third
/// device, a longer title, or a trailing action appearing. What the bar carries
/// is knowable from the bar itself, so the host asks it.
final class LeadingSelectorHost: UIView {
    private let bar: PagedTabBar
    /// The item this host was installed into, so the ceiling can be derived from
    /// what else that item carries. Weak: the navigation item owns the bar
    /// button item, which owns this view.
    private weak var owner: UINavigationItem?
    private var maximumWidth: NSLayoutConstraint!

    init(bar: PagedTabBar, owner: UINavigationItem) {
        self.bar = bar
        self.owner = owner
        super.init(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        // ⚠️ A CEILING, not a width. The first cut stated the width outright —
        // `min(bar.intrinsicContentSize.width, available)` recomputed on layout —
        // and read the bar before its segments had pinned themselves, when the
        // fitted width is just the capsule's own padding. It latched ~32pt and
        // the profile's five-tab selector came out a 36pt stub. Nothing was wrong
        // with the arithmetic; the mistake was owning a number Auto Layout will
        // maintain for free.
        //
        // As an inequality, the bar takes its intrinsic width whenever that fits
        // and the ceiling whenever it does not — re-resolved every time the bar
        // invalidates its own size, with no observation of ours.
        maximumWidth = bar.widthAnchor.constraint(lessThanOrEqualToConstant: 1_000)
        maximumWidth.priority = .required
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            maximumWidth
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateCeiling()
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        updateCeiling()
        super.layoutSubviews()
        // The bar re-measures itself when a badge appears or a text size changes,
        // and this host's size is derived from that — so it has to re-state it
        // rather than keep the number it was first laid out at.
        if abs(lastStatedWidth - intrinsicContentSize.width) > 0.5 {
            lastStatedWidth = intrinsicContentSize.width
            invalidateIntrinsicContentSize()
        }
    }

    private var lastStatedWidth: CGFloat = 0
    #if DEBUG
    private var lastReportedIntrinsic: CGFloat = -1
    #endif

    /// ⚠️ **STATED, not inherited.** The bar's own intrinsic width used to reach
    /// the item through the pinned edges, and that worked only while the bar fit:
    /// once the ceiling bound it, the width had an upper limit and no lower one,
    /// nothing REQUIRED it to be positive, and Auto Layout was free to settle the
    /// host at zero — which is what the profile's five-tab selector did
    /// (`intrinsicW=325`, `hostFrame=(0,0,0,0)`, and UIKit declining to host a
    /// view with no size). Saying the number here gives the item something to
    /// measure and Auto Layout a preference to honour.
    override var intrinsicContentSize: CGSize {
        let wanted = bar.intrinsicContentSize
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-leading-room"),
           abs(lastReportedIntrinsic - wanted.width) > 0.5 {
            lastReportedIntrinsic = wanted.width
            print(String(format: "[leading-room] STATED wants=%.0fx%.0f ceiling=%.0f window=%@",
                         wanted.width, wanted.height, ceiling, window == nil ? "nil" : "yes"))
        }
        #endif
        guard wanted.width > 1 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: wanted.height)
        }
        // Take the whole intrinsic width when it fits and the ceiling when it
        // does not; the ceiling itself never falls below one bubble. Expressed
        // here and not as constraints on the bar — required `>=`/`<=`
        // constraints there fight the bar's own.
        return CGSize(width: min(wanted.width, ceiling), height: wanted.height)
    }

    /// The selector's own minimum: as wide as it is tall.
    ///
    /// ⚠️ This used to be `bar.firstSegmentWidth` — one whole tab, on the reasoning
    /// that a narrower capsule says nothing. It says plenty: the capsule is a
    /// scroller, so a bubble shows the selected tab and reaches every other by a
    /// swipe, and the tab it shows is the one that matters. Demanding a whole tab
    /// is demanding width the bar may not have, and the only thing UIKit does
    /// with a demand it cannot meet is collapse the group.
    private var bubbleWidth: CGFloat { bar.intrinsicContentSize.height }

    /// The widest the bar may be here — the navigation bar's width, less what
    /// everything else on it needs.
    private var ceiling: CGFloat {
        #if DEBUG
        // `-leading-ceiling <points>`: forces the cap, to tell a width failure
        // from a structural one when a surface's selector is not hosted.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-leading-ceiling"),
           position + 1 < arguments.count, let forced = Double(arguments[position + 1]) {
            return CGFloat(forced)
        }
        #endif
        return budget.ceiling(bubbleWidth: bubbleWidth)
    }

    private var budget: LeadingSelectorBudget {
        LeadingSelectorBudget(
            barWidth: hostBarWidth,
            leadingSiblingWidths: leadingSiblingWidths,
            trailingWidths: trailingWidths
        )
    }

    /// ⚠️ The NAVIGATION BAR's width, with the window only as a fallback. They
    /// differ wherever the bar is not the full screen — a regular-width split, a
    /// popover, a form sheet — and the window's number is the optimistic one.
    private var hostBarWidth: CGFloat {
        if let navigationBar = enclosingNavigationBar, navigationBar.bounds.width > 1 {
            return navigationBar.bounds.width
        }
        if let width = window?.bounds.width, width > 1 { return width }
        return UIScreen.main.bounds.width
    }

    private var enclosingNavigationBar: UINavigationBar? {
        var node: UIView? = superview
        while let current = node {
            if let navigationBar = current as? UINavigationBar { return navigationBar }
            node = current.superview
        }
        return nil
    }

    /// What shares the LEADING group with the selector: a back button, another
    /// glyph.
    ///
    /// Derived from the navigation ITEM rather than from the bar's laid-out
    /// subviews, and deliberately: once UIKit has collapsed a group its platters
    /// measure zero, so reading the tree would report acres of free space at
    /// exactly the moment the selector is missing — a ceiling that rises the
    /// worse things get. The item says what the bar is meant to carry whether or
    /// not UIKit managed to draw it.
    private var leadingSiblingWidths: [CGFloat] {
        guard let owner else { return [] }
        // Ours, and hidden ones — the profile hides its selector item while the
        // header owns the un-scrolled state, and a hidden action takes no room.
        var widths = (owner.leftBarButtonItems ?? [])
            .filter { $0.customView !== self && !$0.isHidden }
            .map(Self.wantedWidth)
        if let back = backButtonWidth { widths.append(back) }
        return widths
    }

    /// The trailing group, which rides in ONE shared pill.
    private var trailingWidths: [CGFloat] {
        guard let owner else { return [LeadingSelectorBudget.itemWidth] }
        var widths = (owner.rightBarButtonItems ?? [])
            .filter { !$0.isHidden }
            .map(Self.wantedWidth)
        // An integrated search glyph is a trailing platter that never appears in
        // `rightBarButtonItems` — invisible to the list above, and 44pt wide on
        // the bar. The compose picker wears one.
        if owner.searchController != nil { widths.append(LeadingSelectorBudget.itemWidth) }
        return widths
    }

    /// One platter, when this screen is pushed — or nil at a stack's root.
    ///
    /// ⚠️ **A CHEVRON, never a chevron plus the previous title.** This used to
    /// charge `44 + titleWidth(backTitle)`, on the reasoning that a back button
    /// wearing a word is wider than one that does not. It never wears one: beside
    /// a leading custom view iOS 26 draws the back button as a bare 44pt chevron
    /// platter, measured at x=16 on every pushed profile — above a tab root,
    /// above the Search tab, and above Notifications alike.
    ///
    /// Charging the title is charging room nobody occupies, and the selector pays
    /// for it: pushed above Notifications the budget reserved 101pt for a 44pt
    /// chevron, which squeezed a 206pt capsule down to 82 and left **90pt of dead
    /// space** between it and the Follow button. Arnaud reported exactly that gap.
    private var backButtonWidth: CGFloat? {
        guard let owner, !owner.hidesBackButton,
              let navigationBar = enclosingNavigationBar,
              let items = navigationBar.items, items.count > 1, items.last === owner
        else { return nil }
        return LeadingSelectorBudget.itemWidth
    }

    private static func wantedWidth(of item: UIBarButtonItem) -> CGFloat {
        if let custom = item.customView {
            let intrinsic = custom.intrinsicContentSize.width
            if intrinsic > 0 { return intrinsic }
            let fitted = custom.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            return fitted > 0 ? fitted : LeadingSelectorBudget.itemWidth
        }
        if item.width > 0 { return item.width }
        // A titled action — the profile's Follow capsule — is a good deal wider
        // than a glyph, and charging it 44 is how a bar with one comes out over.
        // ⚠️ Its platter is the TITLE plus padding, not a 44pt platter plus the
        // title: "Following" measures 72pt and rides in a 106pt platter, so the
        // padding is 34 and the old `44 + title` over-charged by 10.
        if let title = item.title, !title.isEmpty {
            return max(
                LeadingSelectorBudget.itemWidth,
                Self.titleWidth(title) + LeadingSelectorBudget.titledItemPadding
            )
        }
        return LeadingSelectorBudget.itemWidth
    }

    private static func titleWidth(_ title: String) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Caps the bar and puts the host's own measurement into its FRAME, before
    /// the item is ever offered to a navigation bar.
    ///
    /// ⚠️ **This is the whole fix, and the reason is a chicken-and-egg.** The
    /// ceiling used to be applied in `layoutSubviews` — which never runs for a
    /// view UIKit has not hosted. So the one measurement that decides whether the
    /// selector is hosted AT ALL was taken with `maximumWidth` still at its
    /// 1000pt placeholder: UIKit asked the uncapped view, got the capsule's full
    /// intrinsic width, decided it did not fit, and swept the entire header —
    /// selector and magnifier both — into a `•••`. The cap then arrived on a view
    /// that no longer had anywhere to be.
    ///
    /// That is also why the collapse looked width-independent: forcing a smaller
    /// ceiling changed a constraint constant nothing had applied yet, so every
    /// forced value measured the same 280pt and every one of them collapsed.
    /// Measured on iPhone SE 3 (375pt): uncapped 280 → `•••`; capped 267 → hosted.
    ///
    /// The frame is set for the same reason. A bar item's custom view keeps
    /// `translatesAutoresizingMaskIntoConstraints`, so the size UIKit reads at
    /// hand-over is this view's frame, and an unlaid host's frame is zero. The
    /// bar is laid out first so its segments have pinned their widths — unlaid,
    /// its fitted width is the capsule's own padding and the frame would be an
    /// 8pt stub.
    func sizeToOwnContent() {
        updateCeiling()
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        let size = intrinsicContentSize
        guard size.width > 1, size.height > 1 else { return }
        frame = CGRect(origin: frame.origin, size: size)
    }

    private func updateCeiling() {
        let target = ceiling
        guard abs(maximumWidth.constant - target) > 0.5 else { return }
        maximumWidth.constant = target
        // The number the item was measured at has changed — a trailing action
        // appeared, the bar rotated, the screen was pushed. Saying so is what
        // carries the new ceiling out to the bar item; the constraint alone
        // reaches only the capsule inside this host.
        invalidateIntrinsicContentSize()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-leading-room") {
            let budget = budget
            let list: ([CGFloat]) -> String = { widths in
                widths.map { String(format: "%.0f", $0) }.joined(separator: ",")
            }
            print(String(format: "[leading-room] barW=%.0f room=%.0f ceiling=%.0f "
                         + "bubble=%.0f wants=%.0f leading=[%@] trailing=[%@]",
                         budget.barWidth, budget.roomForOtherItems, target, bubbleWidth,
                         bar.intrinsicContentSize.width,
                         list(budget.leadingSiblingWidths), list(budget.trailingWidths)))
        }
        #endif
    }
}

/// Hosting a `PagedTabBar` in the navigation bar's LEADING item group instead of
/// its centre title slot.
///
/// The layout every host gets:
///
/// ```
/// [ back / leading icon ] [ selector capsule ]  ——— flexible ———  [ actions ]
/// ```
///
/// One implementation, four hosts. The pattern is five things that all have to be
/// right together — bare rendering, a sized host, a capped width, a cleared title
/// slot, and a leading group that supplements rather than replaces — and a host
/// that gets four of them looks correct while behaving wrongly.
public extension UINavigationItem {
    /// Moves `bar` out of the title slot and into the leading group.
    ///
    /// The selector takes whatever width the rest of this item's contents leave
    /// it, down to a bubble, and scrolls for the rest — so no host has a number
    /// to state, and none can state a wrong one. Where the order is free, add the
    /// trailing actions BEFORE calling this; a later change is picked up on the
    /// next layout either way.
    ///
    /// Returns the item, because a host that hides its selector (the profile,
    /// whose header owns the un-scrolled state) needs it: hiding the BAR leaves
    /// UIKit's capsule behind as an empty pill, and only
    /// `UIBarButtonItem.isHidden` takes the capsule with it.
    @discardableResult
    func installLeadingSelector(_ bar: PagedTabBar) -> UIBarButtonItem {
        // ⚠️ BARE. UIKit wraps a bar item's custom view in the system's glass
        // capsule — "bar items get a capsule, the title slot gets nothing" — so a
        // bar carrying its own backdrop here is a glass lens inside a glass
        // capsule, which is the arrangement that cost the lens its edge entirely.
        // See `PagedTabBar.suppressesBackdrop`.
        bar.suppressesBackdrop = true

        // Sized AND capped; see `LeadingSelectorHost`, which is where the reason
        // a plain `UIView` was not enough is written down.
        let host = LeadingSelectorHost(bar: bar, owner: self)

        // ⚠️ An EMPTY VIEW, not `nil`. Left nil, UIKit keeps a central title
        // reservation and the leading group cannot grow into it — on every width
        // below 440pt the inbox's capsule crossed that invisible threshold and
        // UIKit collapsed the whole leading group into a `•••`, leaving the middle
        // of the bar blank. A zero-sized title view claims the slot and asks for
        // nothing, which releases the space.
        let emptyTitle = UIView()
        emptyTitle.frame = .zero
        titleView = emptyTitle

        // ⚠️ SUPPLEMENTS. A leading item that replaces the back button silently
        // disables the navigation controller's interactive pop gesture — the
        // reason the feed once had to build a whole replacement pan. Harmless on
        // a tab root, where there is no back button to supplement.
        leftItemsSupplementBackButton = true

        // ⚠️ MEASURED AND CAPPED BEFORE THE HAND-OVER. A bar item's custom view
        // keeps `translatesAutoresizingMaskIntoConstraints`, so what UIKit reads
        // when it decides whether to host the item is this view's FRAME — and
        // until now nothing had set one, because the cap and the frame were both
        // applied in `layoutSubviews`, which never runs for a view UIKit has not
        // hosted. See `sizeToOwnContent`.
        host.sizeToOwnContent()
        let item = UIBarButtonItem(customView: host)
        // ⚠️ ITS OWN CAPSULE. iOS 26 draws ONE shared glass background behind
        // adjacent bar items, so the selector and the leading icon came out
        // fused inside a single pill — one container holding a `+` and three
        // tabs. `sharesBackground = false` is UIKit's own opt-out: "this item
        // will not be visually grouped with any other items", while keeping the
        // standard background of its own. `hidesSharedBackground` is the wrong
        // neighbour — it removes the background entirely, and the bar is bare.
        item.sharesBackground = false
        var leading = leftBarButtonItems ?? []
        // Whatever the host already put here keeps its place at the front: the
        // compose glyph on For You, the switcher on an own profile.
        leading.append(item)
        leftBarButtonItems = leading
        return item
    }
}
