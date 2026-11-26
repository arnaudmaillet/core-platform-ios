import UIKit

/// A `PagedTabBar` in the NAVIGATION BAR's leading group, right after the
/// bell — the paged tab roots' one rule (#2337, the owner 2026-11-12): For
/// You's `[bell][Feed | Shots]` since 2026-10-25, Messages'
/// `[bell][Chats | Requests | Suggestions]` since #2337.
///
/// The navigation-bar sibling of `SelectorToolbarItem` (a pushed screen's
/// bottom toolbar) and `SelectorAccessory` (the profile's band). The recipe is
/// For You's — `.navigationTitle`, `.platter` (the bar item's glass draws the
/// capsule), `BarItems.container` under a stable identifier, its own platter
/// after the bell (`BarItems.separator()`) — plus the WIDTH RULE a strip with
/// three counted titles needs and two short ones never did:
///
/// - **The bar never collapses into a `•••`** (R4). The selector is the last
///   priority: it takes what the other items leave (`BarSelectorBudget`),
///   scrolls past that (`PagedTabBar.widthCeiling`), and never asks for less
///   than one bubble (the rule since 2026-08-19).
/// - **15pt if it fits, otherwise 13pt** (`PagedTabBar.TitleSize`), the size
///   the inbox's titles wore in the bar in August.
/// - **The same gap on both sides** (#2577, the owner 2026-11-26): bell →
///   selector = selector → trailing item, measured on the drawn platters
///   (`balanceGaps(in:budget:)`), the platter running to that gap whatever
///   its titles need (`PagedTabBar.fillsCeiling`), the row centred in it.
///
/// ⚠️ **ONE ITEM FOR THE STRIP'S LIFE, AS FOR YOU'S.** A width change (a
/// count, the title size) is told IN PLACE: the strip re-states its
/// intrinsic size and `fit(_:)` answers that it moved, so the host asks its
/// bar to lay out again. The strip's frame is never written: the bar sizes it
/// from its intrinsic size. The one re-mint is after a sweep into a `•••`
/// (`narrowAfterOverflow`): a swept group is measured again only for a new
/// item.
///
/// ⚠️ **AND THE CEILING IS APPLIED BEFORE THE BAR FIRST MEASURES IT.** The
/// host fits the strip as it composes its bar, before the screen is ever on
/// show: measured on 2026-08-19, a cap applied only once the view was hosted
/// was applied to nothing, and the whole toolbar went into a `•••` on an
/// iPhone SE (`navbar-leading-selector-collapse`).
@MainActor
public final class BarSelectorItem {
    /// The strip, as the host built it (titles, badges, its actions).
    public let strip: PagedTabBar
    /// The item's identifier, stable across launches.
    public let id: String
    /// The item the host puts after the bell — the same one for the strip's
    /// life (see the type's note), except after a sweep into a `•••`
    /// (`narrowAfterOverflow`), when only a fresh item makes the bar measure
    /// again.
    public private(set) var item: UIBarButtonItem
    /// Points taken off the budget's ceiling after the bar swept the group.
    public private(set) var trim: CGFloat = 0
    /// How much each sweep takes off.
    public static let trimStep: CGFloat = 24
    /// What keeps the bell and the strip two platters rather than one shared
    /// pill — one instance, so an identical group compares identical.
    private let separator = BarItems.separator()
    /// The width the strip last stated; nil before the first fit.
    private var statedWidth: CGFloat?
    /// The title budget the host last fitted with, kept for the narrowing a
    /// sweep asks for.
    private var lastTitleBudget: BarSelectorBudget?
    /// Points the last balance added to the ceiling (#2577) — what the
    /// budget's estimates missed, as the bar drew it — and the budget it was
    /// measured under. It holds while the budget stays close to that one
    /// (`BarSelectorBudget.isClose(to:)`: the bell's glyph swapped for its
    /// badged one is a point wider); a new bar width or text size drops it.
    public private(set) var balance: CGFloat = 0
    private var balancedBudget: BarSelectorBudget?
    /// Below the width a balance tipped into a sweep, under that budget.
    private var balancedWidthCap = CGFloat.greatestFiniteMagnitude
    /// False once a trim narrowed the strip: a balance then only narrows.
    private var balanceMayWiden = true

    public init(strip: PagedTabBar, id: String) {
        strip.hosting = .platter
        strip.fillsWidth = false
        strip.fillsCeiling = true
        self.strip = strip
        self.id = id
        item = BarItems.container(id: id, view: strip)
    }

    /// The leading group: `[lead][selector]` — the bell, then the strip in a
    /// platter of its own — or the strip alone with nothing to lead it.
    public func leadingGroup(after lead: UIBarButtonItem?) -> [UIBarButtonItem] {
        guard let lead else { return [item] }
        return [lead, separator, item]
    }

    /// Fits the strip to the room `budget` leaves: the title size and the
    /// ceiling. Returns true when the width the strip states moved, so the
    /// host lays its bar out again — the item stays the same.
    ///
    /// `titleBudget`, when given, decides the title size instead of `budget`
    /// (#2411): an item that comes into the bar without taking the titles'
    /// size — the inbox's compose item — narrows the strip, which scrolls,
    /// and no title shrinks for it.
    @discardableResult
    public func fit(_ budget: BarSelectorBudget, titleBudget: BarSelectorBudget? = nil) -> Bool {
        if let balancedBudget, !balancedBudget.isClose(to: budget) {
            self.balancedBudget = nil
            balance = 0
            balancedWidthCap = .greatestFiniteMagnitude
        }
        let ceiling = ceiling(for: budget)
        lastTitleBudget = titleBudget
        let titleRoom = titleBudget.map(self.ceiling(for:)) ?? ceiling
        strip.titleSize = strip.preferredWidth(at: .regular) <= titleRoom + 0.5 ? .regular : .compact
        strip.widthCeiling = ceiling
        let width = strip.intrinsicContentSize.width
        if let statedWidth, abs(statedWidth - width) <= 0.5 { return false }
        statedWidth = width
        return true
    }

    /// The strip view's ceiling under `budget`, plus the balance measured
    /// under it, less any trim — never below one bubble.
    public func ceiling(for budget: BarSelectorBudget) -> CGFloat {
        let bubble = strip.intrinsicContentSize.height
        let ceiling = budget.selectorCeiling(bubble: bubble, ring: strip.hosting.overhang)
        guard balancedBudget?.isClose(to: budget) == true else { return max(bubble, ceiling - trim) }
        return max(bubble, min(ceiling + balance, balancedWidthCap) - trim)
    }

    /// Makes the two gaps the bar DREW equal (#2577): bell → selector and
    /// selector → trailing item, on the platters, once the bar has laid the
    /// strip out. The budget is an estimate — a glyph's bubble is 44pt on the
    /// iOS 27.2 simulator and was 48 on 27.0 (`BarSelectorBudget`) — so the
    /// difference is measured and the ceiling moved by it. Returns true when
    /// the stated width moved: the host lays its bar out again.
    ///
    /// Only where UIKit lets the selector run to the leading spacing before
    /// the trailing group (`BarSelectorBudget.balancesGaps`): on iOS 26 the
    /// bar keeps 24pt there, and a balance would sweep the group into a
    /// `•••`. Never widens past a width that swept (`narrowAfterOverflow`).
    @discardableResult
    public func balanceGaps(in bar: UIView, budget: BarSelectorBudget) -> Bool {
        guard budget.balancesGaps, let gaps = drawnGaps(in: bar) else { return false }
        // Whole points, down: a platter a third of a point past UIKit's
        // minimum sweeps the group (12pt drew, 11 swept).
        var delta = (gaps.trailing - gaps.leading).rounded(.down)
        if !balanceMayWiden { delta = min(delta, 0) }
        guard delta != 0 else { return false }
        let previous = balance
        balance = (balancedBudget?.isClose(to: budget) == true ? balance : 0) + delta
        balancedBudget = budget
        guard fit(budget, titleBudget: lastTitleBudget) else {
            // Held at the cap: nothing moved, nothing to keep.
            balance = previous
            return false
        }
        return true
    }

    /// Whether the strip is on screen in its bar. A bar that swept the
    /// group into a `•••` hosts it nowhere: it has no window.
    public var isHosted: Bool { strip.window != nil }

    /// The gaps `bar` drew before and after the strip's platter, platter to
    /// platter (`BarSelectorGaps`) — nil unless the strip is in `bar` with
    /// an item on screen on each side.
    public func drawnGaps(in bar: UIView) -> (leading: CGFloat, trailing: CGFloat)? {
        guard isHosted, strip.isDescendant(of: bar),
              let gaps = BarSelectorGaps.measure(around: strip, in: bar)
        else { return nil }
        return (gaps.leading, gaps.trailing)
    }

    /// The bar swept the group into a `•••` all the same (its allowance is
    /// UIKit's, and not public): takes `trimStep` off the ceiling, re-fits,
    /// and mints a fresh item under the same identifier so the bar measures
    /// it again — the host writes its leading group with the new `item`.
    /// False, and nothing changed, once the strip is down to one bubble.
    ///
    /// ⚠️ **A STALE WIDTH IS RE-FITTED FIRST, WITHOUT A TRIM** (#2577): the
    /// bell's bubble grows after the first fit at the largest accessibility
    /// sizes (probed: 48 → 88pt at 402, the iPhone SE's group swept), so the
    /// strip states more than `budget` allows. Re-fitted to it and handed
    /// back as a fresh item, it fits; a trim on top would leave the right
    /// gap 24pt wide for good, since a balance never widens after a trim.
    ///
    /// ⚠️ **A SWEEP A BALANCE TIPPED STEPS BACK A POINT, NOT A TRIM**: UIKit's
    /// minimum gap is the leading spacing to the point (12 drew, 11 swept), so
    /// a balance a point too generous is answered a point narrower, and never
    /// wider again under that budget.
    @discardableResult
    public func narrowAfterOverflow(_ budget: BarSelectorBudget) -> Bool {
        let stated = strip.intrinsicContentSize.width
        if stated > ceiling(for: budget) + 0.5 {
            fit(budget, titleBudget: lastTitleBudget)
            item = BarItems.container(id: id, view: strip)
            return true
        }
        if balance > 0, balancedBudget?.isClose(to: budget) == true, stated > strip.intrinsicContentSize.height + 1 {
            balancedWidthCap = stated - 1
            fit(budget, titleBudget: lastTitleBudget)
            item = BarItems.container(id: id, view: strip)
            return true
        }
        guard ceiling(for: budget) > strip.intrinsicContentSize.height + 0.5 else { return false }
        balanceMayWiden = false
        trim += Self.trimStep
        fit(budget, titleBudget: lastTitleBudget)
        item = BarItems.container(id: id, view: strip)
        return true
    }
}

/// The room a navigation bar leaves its leading selector (#2337), and the
/// gap on each side of it (#2577) — the August arithmetic
/// (`navbar-leading-selector-collapse`, measured on iOS 26 at 375pt: 16pt
/// margins, 12pt between leading platters, a trailing group's items sharing
/// one pill at +27pt each after the first, at least 24pt between the two
/// groups), with iOS 27's numbers where they differ.
///
/// ⚠️ **THE AUGUST NUMBERS ALONE SWEPT THE WHOLE GROUP INTO A `•••`** on the
/// iPhone 18 Pro simulator (iOS 27.0): the bar kept room at its trailing end
/// even with no trailing item (`trailingReserve`), and a glyph's bubble was
/// 48pt there. Should a bar still sweep the group, the host narrows the
/// selector (`BarSelectorItem.narrowAfterOverflow`).
///
/// **THE PROBE (#2577, 2026-11-26)** — the selector's ceiling raised past the
/// room step by step, the inbox counting 44 / 8, the platters read off the
/// view hierarchy, on the iOS 27.2 simulators:
///
/// | | iPhone 18 Pro, 402pt | iPhone SE, 375pt |
/// |---|---|---|
/// | a glyph's platter (bell, compose) | 44 × 44 | 44 × 44 |
/// | bell → selector, as drawn | 12 | 12 |
/// | smallest gap before the trailing group, no `•••` | 12 (11 swept) | 12 (11 swept) |
/// | the bell at the largest accessibility size | 88 wide | swept by a stale fit (`narrowAfterOverflow`) |
///
/// - **So on iOS 27 UIKit lets the selector run to the compose item with the
///   leading spacing** (`interGroupGap` = `leadingGap`): the two gaps are the
///   same 12pt. Below that the bar sweeps the WHOLE group, the bell with the
///   selector, into a lone `•••`.
/// - A fixed space after the bell does not widen the leading gap on 27.2
///   (`UIBarButtonItem.fixedSpace(6)` and `(12)` drew the same 12pt), so the
///   other way to equal gaps — widening the left one — is not open there.
/// - **iOS 26: not measured** (no iOS 26 runtime locally; CI's hosts are
///   iOS 26). It keeps the August 24pt before the trailing group, which never
///   swept there, and no balance (`balancesGaps`): the gaps stay 12 / 24 on
///   iOS 26 rather than risk a `•••`.
/// - `platter` stays 48, an estimate on the safe side: the selector is
///   balanced on what the bar drew (`BarSelectorItem.balanceGaps`), so a
///   44pt bubble only leaves the first layout 8pt short.
public struct BarSelectorBudget: Equatable, Sendable {
    public static let barMargin: CGFloat = 16
    /// iOS 27.0's glass bubble (`BarItems.bubbleHeight`): the estimate. The
    /// iOS 27.2 simulator draws 44, as iOS 26 did.
    public static let platter: CGFloat = 48
    /// Between two leading platters, as drawn on iOS 26 and 27.
    public static let leadingGap: CGFloat = 12
    public static let sharedItemSpacing: CGFloat = 27
    /// What the bar keeps at its trailing end with nothing there (not
    /// re-probed by #2577: every bar selector has had a trailing item since).
    public static let trailingReserve: CGFloat = 24
    /// The smallest gap UIKit keeps before a trailing group on this OS (the
    /// probe, above): the leading spacing on iOS 27, August's 24 on iOS 26.
    public static var systemInterGroupGap: CGFloat {
        if #available(iOS 27, *) { leadingGap } else { 24 }
    }

    /// The navigation bar's width.
    public var barWidth: CGFloat
    /// The items before the selector (the bell, a back chevron), each in a
    /// platter of its own: their widths, a glyph's being `platter`.
    public var leadingWidths: [CGFloat]
    /// The trailing group's items, sharing one pill: their widths.
    public var trailingWidths: [CGFloat]
    /// The gap kept before the trailing group: `systemInterGroupGap` unless
    /// a test states one.
    public var interGroupGap: CGFloat

    public init(
        barWidth: CGFloat, leadingWidths: [CGFloat] = [], trailingWidths: [CGFloat] = [],
        interGroupGap: CGFloat = BarSelectorBudget.systemInterGroupGap
    ) {
        self.barWidth = barWidth
        self.leadingWidths = leadingWidths
        self.trailingWidths = trailingWidths
        self.interGroupGap = interGroupGap
    }

    /// Whether the selector alone can make its two gaps equal (#2577): an
    /// item leads it, a group trails it, and UIKit lets it run as close to
    /// that group as the leading spacing.
    public var balancesGaps: Bool {
        !leadingWidths.isEmpty && !trailingWidths.isEmpty && interGroupGap <= Self.leadingGap + 0.5
    }

    /// Whether a balance measured under this budget still holds under
    /// `other`: the same bar and items, each item's estimate within a couple
    /// of points (a glyph swapped for its badged variant), not a new text
    /// size or bar width.
    public func isClose(to other: BarSelectorBudget) -> Bool {
        func close(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 2 }
        }
        return abs(barWidth - other.barWidth) < 0.5 && interGroupGap == other.interGroupGap
            && close(leadingWidths, other.leadingWidths) && close(trailingWidths, other.trailingWidths)
    }

    /// The gap the budget leaves after the selector's platter: before the
    /// trailing group, or at the bar's end without one.
    public var trailingGap: CGFloat { trailingWidths.isEmpty ? Self.trailingReserve : interGroupGap }

    /// The width the selector's PLATTER may take.
    public var room: CGFloat {
        let leading = leadingWidths.reduce(CGFloat.zero) { $0 + max(Self.platter, $1) + Self.leadingGap }
        var trailing = trailingWidths.reduce(CGFloat.zero) { $0 + max(Self.platter, $1) }
        if !trailingWidths.isEmpty {
            trailing += Self.sharedItemSpacing * CGFloat(trailingWidths.count - 1)
        }
        trailing += trailingGap
        return barWidth - Self.barMargin * 2 - leading - trailing
    }

    /// The strip VIEW's ceiling: the room less the platter's ring on each
    /// side, and never below one bubble (`bubble`, the strip's height) —
    /// demanding more than the bar has is how a group becomes a `•••`.
    public func selectorCeiling(bubble: CGFloat, ring: CGFloat) -> CGFloat {
        max(bubble, (room - ring * 2).rounded(.down))
    }

    /// What an item takes in the bar: a custom view its width, a glyph its
    /// bubble — the glyph and `imageInset` each side, never less than a
    /// platter. A titled item is charged a platter too — the inbox's
    /// trailing corner holds none today (#2337 lists what could come).
    ///
    /// ⚠️ **A GLYPH SIZED BY A TEXT STYLE GROWS WITH THE TEXT SIZE** (#2411):
    /// the shell's bell (`textStyle: .body`, `.large`) is a bubble about
    /// 89pt wide at the largest accessibility size on an iPhone 18 Pro, not
    /// 48. Charged a platter, it left the selector room the bar did not
    /// have, and the compose item went into a `•••`.
    @MainActor
    public static func width(of item: UIBarButtonItem) -> CGFloat {
        guard let custom = item.customView else {
            guard let image = item.image else { return platter }
            return max(platter, ceil(image.size.width) + imageInset * 2)
        }
        let intrinsic = custom.intrinsicContentSize.width
        return intrinsic > 0 ? intrinsic : max(platter, custom.bounds.width)
    }

    /// The room a bubble keeps each side of its glyph.
    public static let imageInset: CGFloat = 12
}

/// The gaps a bar DREW either side of its selector (#2577), platter to
/// platter: what `BarSelectorItem.balanceGaps` makes equal.
///
/// The neighbours are found by ROLE, never by class name: the controls
/// UIKit draws a bar's items with (a stock item's button, a custom view
/// that is a control), on the strip's row, outside it — the nearest one
/// wholly before it and the nearest one wholly after it. Each platter is
/// found by SHAPE (`SelectorHosting.measuredPlatterOverhang`): the nearest
/// ancestor larger than the view and centred on it.
struct BarSelectorGaps: Equatable {
    var leading: CGFloat
    var trailing: CGFloat

    /// Nil unless both neighbours are on screen.
    @MainActor
    static func measure(around strip: UIView, in bar: UIView) -> BarSelectorGaps? {
        let selector = platter(of: strip, in: bar)
        var lead: (view: UIView, frame: CGRect)?
        var trail: (view: UIView, frame: CGRect)?
        func walk(_ view: UIView) {
            guard view.window != nil, !view.isHidden, view.alpha > 0.01, view !== strip else { return }
            if view is UIControl, !strip.isDescendant(of: view) {
                let frame = view.convert(view.bounds, to: bar)
                // On the strip's row: the search field stacked under the bar
                // is a control too.
                if frame.width >= 1, frame.minY < selector.midY, frame.maxY > selector.midY {
                    // The outermost control wins a tie (visited first): a
                    // stock item's button holds a narrower one.
                    if frame.maxX <= selector.minX + 0.5, frame.maxX > (lead?.frame.maxX ?? -.infinity) {
                        lead = (view, frame)
                    }
                    if frame.minX >= selector.maxX - 0.5, frame.minX < (trail?.frame.minX ?? .infinity) {
                        trail = (view, frame)
                    }
                }
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        guard let lead, let trail else { return nil }
        return BarSelectorGaps(
            leading: selector.minX - platter(of: lead.view, in: bar).maxX,
            trailing: platter(of: trail.view, in: bar).minX - selector.maxX
        )
    }

    /// `view`'s glass in `bar`'s space: its frame grown by the platter's
    /// ring, or the frame itself when nothing around it looks like one.
    @MainActor
    static func platter(of view: UIView, in bar: UIView) -> CGRect {
        let ring = SelectorHosting.measuredPlatterOverhang(around: view) ?? .zero
        return view.convert(view.bounds, to: bar).insetBy(dx: -ring.width, dy: -ring.height)
    }
}
