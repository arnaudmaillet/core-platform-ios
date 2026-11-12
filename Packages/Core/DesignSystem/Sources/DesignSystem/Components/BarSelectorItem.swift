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
///
/// ⚠️ **ONE ITEM FOR THE STRIP'S LIFE, AS FOR YOU'S — NEVER RE-MINTED.** The
/// first cut minted a fresh item around the same strip on every width change
/// (the wallet badge's cure for a frozen width), several times during the
/// screen's load and its layout passes. On the simulator the inbox's strip
/// was then found in no window (`-pill-drag-probe` read `bar=0`) and the bell
/// was gone from the header — and handing one strip from item to item is the
/// one thing For You's working recipe never does. A width change is told IN PLACE: the strip re-states its intrinsic size and
/// `fit(_:)` answers that it moved, so the host asks its bar to lay out again.
/// Nor is the strip's frame written: the bar sizes it from its intrinsic size,
/// as For You's.
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
    /// life (see the type's note).
    public let item: UIBarButtonItem
    /// What keeps the bell and the strip two platters rather than one shared
    /// pill — one instance, so an identical group compares identical.
    private let separator = BarItems.separator()
    /// The width the strip last stated; nil before the first fit.
    private var statedWidth: CGFloat?

    public init(strip: PagedTabBar, id: String) {
        strip.hosting = .platter
        strip.fillsWidth = false
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
    @discardableResult
    public func fit(_ budget: BarSelectorBudget) -> Bool {
        let ceiling = budget.selectorCeiling(bubble: strip.intrinsicContentSize.height,
                                             ring: strip.hosting.overhang)
        strip.titleSize = strip.preferredWidth(at: .regular) <= ceiling + 0.5 ? .regular : .compact
        strip.widthCeiling = ceiling
        let width = strip.intrinsicContentSize.width
        if let statedWidth, abs(statedWidth - width) <= 0.5 { return false }
        statedWidth = width
        return true
    }
}

/// The room a navigation bar leaves its leading selector (#2337) — the
/// August arithmetic (`navbar-leading-selector-collapse`, measured on iOS 26
/// at 375pt): 16pt margins, a 44pt platter per item, 12pt between leading
/// platters, a trailing group's items sharing one pill (+27pt each after the
/// first), and at least 24pt between the two groups.
///
/// On a 402pt bar with the bell alone, 314pt for the selector's platter; on
/// an iPhone SE (375pt), 287.
public struct BarSelectorBudget: Equatable, Sendable {
    public static let barMargin: CGFloat = 16
    public static let platter: CGFloat = 44
    public static let leadingGap: CGFloat = 12
    public static let sharedItemSpacing: CGFloat = 27
    public static let interGroupGap: CGFloat = 24

    /// The navigation bar's width.
    public var barWidth: CGFloat
    /// The items before the selector (the bell, a back chevron), each in a
    /// platter of its own: their widths, a glyph's being `platter`.
    public var leadingWidths: [CGFloat]
    /// The trailing group's items, sharing one pill: their widths.
    public var trailingWidths: [CGFloat]

    public init(barWidth: CGFloat, leadingWidths: [CGFloat] = [], trailingWidths: [CGFloat] = []) {
        self.barWidth = barWidth
        self.leadingWidths = leadingWidths
        self.trailingWidths = trailingWidths
    }

    /// The width the selector's PLATTER may take.
    public var room: CGFloat {
        let leading = leadingWidths.reduce(CGFloat.zero) { $0 + max(Self.platter, $1) + Self.leadingGap }
        var trailing = trailingWidths.reduce(CGFloat.zero) { $0 + max(Self.platter, $1) }
        if !trailingWidths.isEmpty {
            trailing += Self.sharedItemSpacing * CGFloat(trailingWidths.count - 1) + Self.interGroupGap
        }
        return barWidth - Self.barMargin * 2 - leading - trailing
    }

    /// The strip VIEW's ceiling: the room less the platter's ring on each
    /// side, and never below one bubble (`bubble`, the strip's height) —
    /// demanding more than the bar has is how a group becomes a `•••`.
    public func selectorCeiling(bubble: CGFloat, ring: CGFloat) -> CGFloat {
        max(bubble, (room - ring * 2).rounded(.down))
    }

    /// What an item takes in the bar: a custom view its width, a glyph a
    /// platter. A titled item is charged a platter too — the inbox's
    /// trailing corner holds none today (#2337 lists what could come).
    @MainActor
    public static func width(of item: UIBarButtonItem) -> CGFloat {
        guard let custom = item.customView else { return platter }
        let intrinsic = custom.intrinsicContentSize.width
        return intrinsic > 0 ? intrinsic : max(platter, custom.bounds.width)
    }
}
